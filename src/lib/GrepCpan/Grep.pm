package GrepCpan::Grep;

use v5.036;
use GrepCpan::std;

use Git::Repository ();
use Sereal          ();

=pod

git grep -l to a file to cache the result ( limit it to 200 files and run it in background after ?? )
use this list for pagination
then do a query for a set of files with context

grepcpan@grep.cpan.me [~/minicpan_grep.git]# time git grep -C15 -n xyz HEAD | head -n 200

=cut

use Simple::Accessor qw{
    config git cache distros_per_page search_context
    search_context_file search_context_distro
    git_binary root HEAD
};

use POSIX              qw{:sys_wait_h setsid};
use Proc::ProcessTable ();
use Time::HiRes        ();
use File::Path         ();
use File::Slurp        ();
use IO::Handle         ();
use Fcntl              qw(:flock SEEK_END);

use FindBin;
use utf8;

use Digest::MD5 qw( md5_hex );

use constant END_OF_FILE_MARKER => qq{##______END_OF_FILE_MARKER______##};
use constant TOO_BUSY_MARKER    => qq{##______TOO_BUSY_MARKER______##};

use constant CACHE_IS_ENABLED => 1;

sub _build_git($self) {

    my $gitdir = $self->massage_path( $self->config()->{'gitrepo'} );
    die qq{Invalid git directory $gitdir}
        unless defined $gitdir && -d $gitdir;

    return Git::Repository->new(
        work_tree => $gitdir,
        { git => $self->git_binary }
    );
}

sub _build_git_binary($self) {

    my $git = $self->config()->{'binaries'}->{'git'};
    return $git if $git && -x $git;
    $git = qx{which git};
    chomp $git;

    return $git;
}

sub _build_HEAD($self) {

    my $head = $self->git()->run(qw{rev-parse --short HEAD});
    chomp $head if defined $head;
    die unless length($head);

    return $head;
}

sub cpan_index_at($self) {

    my $now          = time();
    my $last_refresh = $self->{_cpan_index_last_refresh_at} // 0;

    # cache the value for 90 minutes
    if ( !$last_refresh || ( $now - $last_refresh ) > ( 60 * 90 ) ) {
        $self->{_cpan_index_last_refresh_at} = $now;
        $self->{_cpan_index_at}              = $self->_build_cpan_index_at();
    }

    return $self->{_cpan_index_at};
}

sub _build_cpan_index_at($self) {

    # git log -n1 --date=format:'%B %-d %Y' --pretty=format:'%ad'
    my $out = $self->git()->run(
        'log',                        '-n1',
        q[--date=format:'%B %-d %Y'], q[--pretty=format:'%ad']
    ) // '';
    chomp $out;
    $out =~ s{['"]}{}g;

    return $out;
}

sub _build_cache($self) {

    my $dir
        = $self->_current_cache_version_directory() . '/HEAD-' . $self->HEAD;

    $dir = $self->massage_path($dir);

    return $dir if -d $dir;

    File::Path::make_path( $dir, { mode => 0711, } )
        or die "Failed to create $dir: $!";
    die unless -d $dir;

    # cleanup after directory structure creation
    $self->cache_cleanup($dir);

    return $dir;
}

sub _current_cache_version_directory($self) {

    return ( $self->config()->{'cache'}->{'directory'} ) . '/'
        . ( $self->config()->{'cache'}->{'version'} || 0 );
}

sub _build_root($self) {

    # hard code root dir in production
    return $self->config()->{'root_dir'} if $self->config()->{'root_dir'};

    return $FindBin::Bin . '/';
}

sub cache_cleanup( $self, $current_cachedir = undef ) {    # aka tmpwatch

    return unless $current_cachedir;

    my @path = split qr{/}, $current_cachedir;

    if ( my $cache_root = $self->config()->{'cache'}->{'directory'} ) {

        # purge old cache versions
        if ( opendir( my $tmp_dh, $cache_root ) ) {
            foreach my $dir ( readdir($tmp_dh) ) {
                next if $dir eq '.' || $dir eq '..';
                my $fdir = $cache_root . '/' . $dir;
                next
                    if $dir eq
                    ( $self->config()->{'cache'}->{'version'} || 0 );
                next if -l $fdir;
                next unless -d $fdir;
                next unless length $fdir > 5;

         # kind of dangerous but should be ok, we are controlling these values
                File::Path::remove_tree( $fdir, { safe => 1 } )
                    or warn "Failed to remove $fdir: $!";
            }
        }
    }

    if ( my $version_cache = $self->_current_cache_version_directory() ) {

        # purge old HEAD directories for the same version
        if ( opendir( my $tmp_dh, $version_cache ) ) {
            foreach my $dir ( readdir($tmp_dh) ) {
                next if $dir eq '.' || $dir eq '..';
                my $fdir = $version_cache . '/' . $dir;
                next if -l $fdir;
                next unless -d $fdir;
                next if $fdir eq $current_cachedir;

                # purge old cache, in the same weird fashion
                File::Path::remove_tree( $fdir, { safe => 1 } )
                    or warn "Failed to remove $fdir: $!";
            }
        }
    }

    return;
}

sub massage_path ( $self, $s ) {

    return unless length $s;

    my $appdir = $self->root;
    $appdir =~ s{/(?:bin|t)/?$}{};

    $s =~ s{~APPDIR~}{$appdir}g;

    return $s;
}

## TODO factorize
# Define builder methods for integer configuration values
BEGIN {
    # initialize (integer) value from config
    foreach my $key (
        qw{distros_per_page search_context search_context_distro search_context_file}
        )
    {
        my $sub  = '_build_' . $key;
        my $code = sub ($self) {
            my $v = $self->config()->{limit}{$key};
            die "Missing configuration for limit.$key" unless defined $v;
            return int($v);
        };

        # Install the method in the current package
        no strict 'refs';    ## no critic qw(ProhibitNoStrict)
        *$sub = $code;
    }
}

sub _sanitize_search($s) {

    return undef unless defined $s;
    $s =~ s{\n}{}g;
    $s =~ s{'}{\'}g;

    # whitelist possible characters ?
    $s =~ s{[^\^a-zA-Z0-9\-\.\?\\*\&_'"~!\$\%()\[\]\{\}:;<>,/\@| =]}{.}g;

    return $s;
}

sub _get_git_grep_flavor($s) {

    # regular characters
    return q{--fixed-string}
        if !defined $s || $s =~ qr{^[a-zA-Z0-9&_'"~:;<>,/ =]+$};
    return q{-P};
}

# idea use git rev-parse HEAD to include it in the cache name

sub do_search ( $self, %opts ) {

    my ( $search, $search_distro, $search_file, $filetype,
        $caseinsensitive, $ignore_files, )
        = (
        $opts{search},          $opts{search_distro},
        $opts{search_file},     $opts{filetype},
        $opts{caseinsensitive}, $opts{ignore_files},
        );

    my $t0 = [Time::HiRes::gettimeofday];

    my $gitdir = $self->git()->work_tree;

    $search = _sanitize_search($search);

    my $results = $self->_do_search(%opts);

    my $cache             = $results->{cache};
    my $output            = $results->{output};
    my $is_a_known_distro = $results->{is_a_known_distro};

    my $elapsed = sprintf( "%.3f",
        Time::HiRes::tv_interval( $t0, [Time::HiRes::gettimeofday] ) );

    return {
        is_incomplete      => $cache->{is_incomplete}      || 0,
        search_in_progress => $cache->{search_in_progress} || 0,
        match              => $cache->{match},
        adjusted_request   => $cache->{adjusted_request} // {},
        results            => $output,
        time_elapsed       => $elapsed,
        is_a_known_distro  => $is_a_known_distro,
        version            => $self->current_version(),
    };
}

sub _do_search ( $self, %opts ) {

    my ( $search, $page, $search_distro, $search_file,
        $filetype, $caseinsensitive, $ignore_files )
        = (
        $opts{search}, $opts{page}, $opts{search_distro}, $opts{search_file},
        $opts{filetype}, $opts{caseinsensitive}, $opts{ignore_files}
        );

    $page //= 0;
    $page = 0 if $page < 0;

    #
    my $cache = $self->_get_match_cache( $search, $search_distro, $filetype,
        $caseinsensitive, $ignore_files );

    my $is_a_known_distro
        = defined $search_distro
        && length $search_distro
        && exists $cache->{distros}->{$search_distro};

    my $context = $self->search_context();    # default context
    if ( defined $search_file ) {
        $context = $self->search_context_file();
    }
    elsif ($is_a_known_distro) {
        $context = $self->search_context_distro();
    }

    my $files_to_search
        = $self->get_list_of_files_to_search( $cache, $search, $page,
        $search_distro, $search_file, $filetype );    ## notidy

    # can also probably simply use Git::Repo there
    my $matches;

    if ( scalar @$files_to_search ) {
        my $flavor  = _get_git_grep_flavor($search);
        my @git_cmd = ('grep');
        push @git_cmd, '-i' if $caseinsensitive;
        push @git_cmd,
            (
            '-n', '--heading', '-C', $context, $flavor, '-e', $search, '--',
            @$files_to_search
            );
        my @out = $self->git->run(@git_cmd);
        $matches = \@out;
    }

    # now format the output in order to be able to use it
    my @output;
    my $current_file;
    my @diffblocks;
    my $diff = '';
    my $line_number;
    my $start_line;
    my @matching_lines;

    my $add_block = sub {
        return unless $diff && length($diff);
        push @diffblocks,
            {
            code       => $diff,
            start_at   => $start_line || 1,
            matchlines => [@matching_lines]
            };
        return;
    };

    my $process_file = sub {
        return unless defined $current_file;
        $add_block->();    # push the last block

        my ( $where, $distro, $shortpath ) = massage_filepath($current_file);
        return unless length $shortpath;
        my $prefix = join '/', $where, $distro;

        my $result = $cache->{distros}->{$distro} // {};
        $result->{distro}  //= $distro;
        $result->{matches} //= [];

        #@diffblocks = scalar @diffblocks; # debugging clear the blocks
        push @{ $result->{matches} },
            { file => $shortpath, blocks => [@diffblocks] };
        return
            if scalar @output
            && $output[-1] eq
            $result;    # same hash do not add it more than once
        push @output, $result;

        return;
    };

    my $previous_file;
    my $qr_match_line = qr{^([0-9]+)([-:])};

    foreach my $line (@$matches) {
        if ( !defined $current_file ) {

     # when more than one block match we are just going to have a -- separator
            if ( $line =~ m{^distros/} ) {
                $previous_file = $current_file = $line;
                next;
            }
            $current_file //= $previous_file;
        }

        if ( $line eq '--' ) {

        # we found a new block, it's either from the current file or a new one
            $process_file->();
            undef $current_file;    # reset: could use previous or next file
            $diff       = '';
            @diffblocks = ();
            undef $start_line;
            undef $line_number;
            @matching_lines = ();
            next;
        }

        # matching the main part
        next unless $line =~ s/$qr_match_line//;
        my ( $new_line, $prefix ) = ( $1, $2 );

        $start_line //= $new_line;
        if ( length($line) > 250 )
        {    # max length autorized ( js minified & co )
            $line = substr( $line, 0, 250 ) . '...';
        }
        if ( !defined $line_number || $new_line == $line_number + 1 ) {

            # same block
            push @matching_lines, $new_line if $prefix eq ':';
            $diff .= $line . "\n";
        }
        else {
            # new block
            $add_block->();
            $diff = $line . "\n";    # reset the block
        }
        $line_number = $new_line;

    }
    $process_file->();    # process the last block

    # update results...
    #update_match_counter( $cache );

    return {
        cache             => $cache,
        output            => \@output,
        is_a_known_distro => $is_a_known_distro
    };
}

sub update_match_counter($cache) {    # dead

    my ( $count_distro, $count_files ) = ( 0, 0 );
    foreach my $distro ( sort keys %{ $cache->{distros} } ) {
        my $c
            = eval { scalar @{ $cache->{distros}->{$distro}->{matches} } }
            // 0;
        next unless $c;
        ++$count_distro;
        $count_files += $c;
    }

    $cache->{match} = {
        files   => $count_files,
        distros => $count_distro
    };

    return;
}

sub current_version($self) {
    my $now       = time();
    my $cache_ttl = 600;      # 10 minutes in seconds

    # Check if we need to refresh the cache
    if (   !exists $self->{__version__}
        || !exists $self->{__version_timestamp__}
        || ( $now - $self->{__version_timestamp__} ) > $cache_ttl )
    {

        $self->{__version__} = join(
            '-',
            $grepcpan::VERSION,
            'cache' => $self->config()->{'cache'}->{'version'},
            'cpan' =>
                eval { scalar $self->git->run(qw{rev-parse --short HEAD}) }
                // '',
        );

        $self->{__version_timestamp__} = $now;
    }

    return $self->{__version__};
}

sub get_list_of_files_to_search( $self, $cache, $search, $page, $distro,
    $search_file, $filetype )
{

# try to get one file per distro except if we do not have enough distros matching
# maybe sort the files by distros having the most matches ??

    my @flat_list;    # full flat list before pagination

    # if we have enough distros
    my $limit = $self->distros_per_page;
    if ( defined $distro && exists $cache->{distros}->{$distro} ) {

        # let's pick all the files for this distro: as we are looking for it
        return [] unless exists $cache->{distros}->{$distro};
        my $prefix = $cache->{distros}->{$distro}->{prefix};
        @flat_list = map { $prefix . '/' . $_ }
            @{ $cache->{distros}->{$distro}->{files} };    # all the files
        if ( defined $search_file ) {
            @flat_list = grep { $_ eq $prefix . '/' . $search_file }
                @flat_list;    # make sure the file is known and sanitize
        }
    }
    else {                     # pick one single file per distro
        @flat_list = map {
            my $distro = $_;  # warning this is over riding the input variable
            my $prefix        = $cache->{distros}->{$distro}->{prefix};
            my $list_of_files = $cache->{distros}->{$distro}->{files};
            my $candidate     = $list_of_files->[0];    # only the first file
            if ( scalar @$list_of_files > 1 ) {

                # try to find a more perlish file first
                foreach my $f (@$list_of_files) {
                    if ( $f =~ qr{\.p[lm]$} ) {
                        $candidate = $f;
                        last;
                    }
                }
            }

            # use our best candidate ( and add our prefix )
            $prefix . '/' . $candidate;
            }
            grep {
            my $key  = $_;
            my $keep = 1;

            # check if there is a distro filter and apply it
            if ( defined $distro && length $distro ) {
                $keep = $key =~ qr{$distro}i ? 1 : 0;
            }
            $keep;
            }
            sort keys %{ $cache->{distros} };
    }

    # now do the pagination
    # page 0: from 0 to limit - 1
    # page 1: from limit to 2 * limit - 1
    # page 2: from 2*limit to 3 * limit - 1

    my @short;
    my $offset = $page * $limit;
    if ( $offset <= scalar @flat_list ) {    # offset protection
        @short = splice( @flat_list, $page * $limit, $limit );
    }

    return \@short;
}

sub _save_cache ( $self, $cache_file, $cache ) {

    # cache is disabled
    return if $self->config()->{nocache};

    Sereal::write_sereal( $cache_file, $cache );

    my $raw_cache_file = $cache_file . '.raw';
    unlink($raw_cache_file) if -e $raw_cache_file;

    return;
}

sub _get_cache_file ( $self, $keys, $type = undef ) {

    $type //= q[search-ls];
    $type .= '-';

    my $cache_file
        = ( $self->cache() // '' ) . '/'
        . $type
        . md5_hex( join( q{|}, map { defined $_ ? $_ : '' } @$keys ) )
        . '.cache';

    return $cache_file;
}

sub _load_cache ( $self, $cache_file ) {

    return unless CACHE_IS_ENABLED;

    # cache is disabled
    return if $self->config()->{nocache};

    return unless defined $cache_file && -e $cache_file;
    return Sereal::read_sereal($cache_file);
}

sub _parse_and_check_query_filetype ( $self, $query_filetype, $adjusted_request={} ) {

    return unless length $query_filetype;

    my $rules = $self->_parse_query_filetype($query_filetype);

    my $r = $rules // [];
    my $value = join( ',', @$r );
    $query_filetype =~ s{\s+}{}g;
    if ( $query_filetype ne $value ) {
        $adjusted_request->{'qft'} = {
            error => "Incorrect search filter: invalid characters - $query_filetype",
            value  => $value,
        }
    }

    return $rules;
}

sub _parse_query_filetype ( $self, $query_filetype ) {

    return unless defined $query_filetype;
    return unless length $query_filetype;

    my @filetypes = split( /\s*,\s*/, $query_filetype );
    @filetypes
        = grep { length($_) && m{^ [a-zA-Z0-9_\-\.\*]+ $}x } @filetypes;

    # ignore rules using '..'
    return if grep {m{\.\.}} @filetypes;

    return \@filetypes;
}

sub _parse_and_check_ignore_files ( $self, $ignore_files, $adjusted_request={} ) {

    return unless length $ignore_files;

    my $rules = $self->_parse_ignore_files($ignore_files);

    if ( ! $rules ) {
        $adjusted_request->{'qifl'} = {
            error => "Incorrect ignore files: invalid characters.",
            value  => $ignore_files, # not updated
        }
    }

    return $rules;
}


# convert a string of patterns (file to exclude) to a list of git rules to ignore the path
# t/*, *.md, *.json, *.yaml, *.yml, *.conf, cpanfile, LICENSE, MANIFEST, INSTALL, Changes, Makefile.PL, Build.PL, Copying, *.SKIP, *.ini, README
sub _parse_ignore_files ( $self, $ignore_files ) {

    return unless length $ignore_files;

    my @ignorelist = grep { length($_) && m{^ [a-zA-Z0-9_\-\.\*/]+ $}x }
        split( /\s*,\s*/, $ignore_files );

    # ignore rules using '..'
    return if grep {m{\.\.}} @ignorelist;

    return unless scalar @ignorelist;

    my @rules;
    foreach my $ignore (@ignorelist) {
        $ignore = '/*' . $ignore unless $ignore =~ m{^\*};
        push @rules, qq[:!$ignore];
    }

    return \@rules;
}

sub _get_match_cache(
    $self, $search, $search_distro, $query_filetype,
    $caseinsensitive = 0,
    $ignore_files = undef
    )
{

    $caseinsensitive //= 0;

    my $gitdir = $self->git()->work_tree;
    my $limit  = $self->config()->{limit}->{files_per_search} or die;

    my $flavor  = _get_git_grep_flavor($search);
    my @git_cmd = qw{grep -l};
    push @git_cmd, q{-i} if $caseinsensitive;
    push @git_cmd, $flavor, '-e', $search, q{--}, q{distros/};

    my @keys_for_cache = (
        $flavor,          $caseinsensitive ? 1 : 0,
        $search,          $search_distro, $query_filetype,
        $caseinsensitive, $ignore_files // ''
    );

    # use the full cache when available -- need to filter it later
    my $request_cache_file = $self->_get_cache_file( \@keys_for_cache );
    if ( my $load = $self->_load_cache($request_cache_file) ) {
        return $load if $load;
    }

    my $adjusted_request = {};

    $search_distro =~ s{::+}{-}g if defined $search_distro;

    # the distro can either come from url or the query with some glob
    if (   defined $search_distro
        && length($search_distro)
        && $search_distro =~ qr{^([0-9a-zA-Z_\*])[0-9a-zA-Z_\*\-]*$} )
    {
        # replace the disros search
        $git_cmd[-1]
            = q{distros/}
            . $1 . '/'
            . $search_distro
            . '/*';    # add a / to do not match some other distro
    }

    # filter on some type files distro + query filetype
    if ( my $rules = $self->_parse_and_check_query_filetype($query_filetype, $adjusted_request) ) {
        my $base_search   = $git_cmd[-1];
        my $is_first_rule = 1;
        foreach my $rule (@$rules) {

            my $search = $base_search . '*' . $rule;

            if ($is_first_rule) {
                $git_cmd[-1] = $search;
                $is_first_rule = 0;
                next;
            }

            push @git_cmd, $search;
        }
    }

    if ( my $rules = $self->_parse_and_check_ignore_files($ignore_files, $adjusted_request) ) {
        push @git_cmd, $rules->@*;
    }

    # fallback to a shorter search ( and a different cache )
    my $cache_file = $self->_get_cache_file( [@git_cmd] );
    if ( my $load = $self->_load_cache($cache_file) ) {
        return $load if $load;
    }

    my $raw_cache_file = $cache_file . q{.raw};

    my $raw_limit = $self->config()->{limit}->{files_git_run_bg};

    my $list_files = $self->run_git_cmd_limit(
        cache_file       => $raw_cache_file,
        cmd              => [@git_cmd],     # git command
        limit            => $limit,
        limit_bg_process => $raw_limit,     #files_git_run_bg
                                            #pre_run => sub { chdir($gitdir) }
    );

    # remove the final marker if there
    my $search_in_progress = 1;

    #say "LAST LINE .... " . $list_files->[-1];
    #say " check  ? ", $list_files->[-1] eq END_OF_FILE_MARKER() ? 1 : 0;
    if ( scalar @$list_files && $list_files->[-1] eq END_OF_FILE_MARKER() ) {
        pop @$list_files;
        $search_in_progress = 0;
    }

    my $cache = {
        distros            => {},
        search             => $search,
        search_in_progress => $search_in_progress
    };
    my $match_files = scalar @$list_files;
    $cache->{is_incomplete} = 1 if $match_files >= $raw_limit;

    my $last_distro;
    foreach my $line (@$list_files) {
        my ( $where, $distro, $shortpath ) = massage_filepath($line);
        next unless defined $shortpath;
        $last_distro = $distro;
        my $prefix = join '/', $where, $distro;
        $cache->{distros}->{$distro} //= { files => [], prefix => $prefix };
        push @{ $cache->{distros}->{$distro}->{files} }, $shortpath;
    }

    if ( $cache->{is_incomplete} )
    {    # flag the last distro as potentially incomplete
        $cache->{distros}->{$last_distro}->{'is_incomplete'} = 1;
    }

    $cache->{match} = {
        files   => $match_files,
        distros => scalar keys $cache->{distros}->%*,
    };
    $cache->{adjusted_request} = $adjusted_request;

    if ( !$search_in_progress ) {

        #say "Search in progress..... done caching yaml file";
        $self->_save_cache( $request_cache_file, $cache );
        $self->_save_cache( $cache_file,         $cache );
        unlink $raw_cache_file if -e $raw_cache_file;
    }

    return $cache;
}

sub massage_filepath ($line) {
    my ( $where, $letter, $distro, $shortpath ) = split( q{/}, $line, 4 );
    $where  //= '';
    $letter //= '';
    $where .= '/' . $letter;
    return ( $where, $distro, $shortpath );
}

sub run_git_cmd_limit ( $self, %opts ) {

    my $cache_file = $opts{cache_file};
    my $cmd        = $opts{cmd} // die;
    ref $cmd eq 'ARRAY' or die "cmd should be an ARRAY ref";
    my $limit            = $opts{limit}            || 10;
    my $limit_bg_process = $opts{limit_bg_process} || $limit;

    my @lines;

    if ( $cache_file && -e $cache_file && !$self->config()->{nocache} ) {

        # check if the file is empty and has more than X seconds

        while ( waitpid( -1, WNOHANG ) > 0 ) {
            1;
        };    # catch any zombies we could have from previous run

        if ( -z $cache_file ) {    # the file is empty
            my ( $mtime, $ctime ) = ( stat($cache_file) )[ 9, 10 ];
            $mtime //= 0;
            $ctime //= 0;

            # return an empty cache if the file exists and is empty...
            return [] if ( time() - $mtime < 60 * 30 );

            # give it a second try after some time...
        }
        else {
            # return the content of our current cache from previous run
            #say "use our cache from previous run";
            my @from_cache = File::Slurp::read_file($cache_file);
            chomp @from_cache;
            return \@from_cache;
        }
    }

    local $| = 1;
    local $SIG{'USR1'} = sub {exit}; # avoid a race condition and exit cleanly

    #my $child_pid = open( my $from_kid, "-|" ) // die "Can't fork: $!";

    local $SIG{'CHLD'} = 'DEFAULT';

    my ( $from_kid, $CW ) = ( IO::Handle->new(), IO::Handle->new() );
    pipe( $from_kid, $CW ) or die "Fail to pipe $!";
    $CW->autoflush(1);

    my $child_pid = fork();
    die "Fork failed" unless defined $child_pid;

    local $SIG{'ALRM'} = sub { die "Alarm signal triggered - $$" };

    if ($child_pid) {    # parent process
        my $c = 1;
        alarm( $self->config->{timeout}->{user_search} );
        eval {
            while ( my $line = readline($from_kid) ) {
                chomp $line;
                if ( $c == 1 && $line eq TOO_BUSY_MARKER() ) {
                    return [];
                }
                push @lines, $line;
                last if ++$c > $limit;

                #say "GOT: $line ", $line eq END_OF_FILE_MARKER() ? 1 : 0;
                last if $line eq END_OF_FILE_MARKER();
            }
            alarm(0);
            1;
        };    # or warn $@;
        close($from_kid);
        kill 'USR1' => $child_pid;
        while ( waitpid( -1, WNOHANG ) > 0 ) {
            1;
        };    # catch what we can at this step... the process is running in bg
    }
    else {
        # in kid process
        local $| = 1;
        my $current_pid       = $$;
        my $can_write_to_pipe = 1;
        local $SIG{'USR1'} = sub {    # not really used anymore
                                      #warn "SIGUSR1.... start";
            $can_write_to_pipe = 0;
            close($CW);
            open STDIN,  '>', '/dev/null';
            open STDOUT, '>', '/dev/null';
            open STDERR, '>', '/dev/null';
            setsid();

            return;
        };

        #kill 'USR1' => $$; # >>>>
        my $run;

        local $SIG{'ALRM'} = sub {
            warn "alarm triggered while running git command";

            if ( ref $run ) {
                my $pid;
                local $@;
                $pid = eval { $run->pid };
                if ($pid) {
                    warn "killing 'git' process $pid...";
                    if ( kill( 0, $pid ) ) {
                        sleep 2;
                        kill( 9, $pid );
                    }
                }
            }

            die
                "alarm triggered while running git command: git grep too long...";
        };

        # limit our search in time...
        alarm( $self->config->{timeout}->{grep_search} // 600 )
            ;    # make sure we always have a value set
        $opts{pre_run}->() if ref $opts{pre_run} eq 'CODE';

        my $lock = $self->check_if_a_worker_is_available();
        if ( !$lock ) {
            print {$CW} TOO_BUSY_MARKER() . "\n";
            exit 42;
        }

        say "Running in kid command: " . join( ' ', 'git', @$cmd );
        say "KID is caching to file ", $cache_file;

        my $to_cache;

        if ($cache_file) {
            $to_cache = IO::Handle->new;
            open( $to_cache, q{>}, $cache_file )
                or die "Cannot open cache file: $!";
            $to_cache->autoflush(1);
        }

        $run = $self->git->command(@$cmd);
        my $log     = $run->stdout;
        my $counter = 1;

        while ( readline $log ) {
            print {$CW} $_
                if $can_write_to_pipe;    # return the line to our parent
            if ($cache_file) {
                print {$to_cache} $_ or die;    # if file is removed
            }
            last if ++$counter > $limit_bg_process;
        }
        $run->close;
        print {$to_cache}
            qq{\n};    # in case of the last line did not had a newline
        print {$to_cache} END_OF_FILE_MARKER() . qq{\n} if $cache_file;
        print {$CW} END_OF_FILE_MARKER() . qq{\n}       if $can_write_to_pipe;
        say "-- Request finished by kid: $counter lines - "
            . join( ' ', 'git', @$cmd );
        exit $?;
    }

    return \@lines;
}

sub check_if_a_worker_is_available($self) {

    my $maxworkers = $self->config->{maxworkers} || 1;

    my $dir = $self->cache();
    return unless -d $dir;

    foreach my $id ( 1 .. $maxworkers ) {
        my $f = $dir . '/worker-id-' . $id;
        open( my $fh, '>', $f ) or next;
        if ( flock( $fh, LOCK_EX | LOCK_NB ) ) {
            seek( $fh, 0, SEEK_END );
            print {$fh} "$$\n";
            return $fh;
        }
    }

    return;
}

1;
