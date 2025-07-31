package SEO::Checker;
use strict;
use warnings;
use LWP::UserAgent;
use HTML::TreeBuilder;
use URI;
use JSON qw(decode_json);
use Encode qw(decode);
use HTTP::Request;
use Try::Tiny;

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        ua      => LWP::UserAgent->new,
        url     => $args{url},
        mobile  => $args{mobile} // 0,
        keyword => $args{keyword},
        tree    => undef,
        final_url => undef,
        base_uri  => undef,
    }, $class;

    $self->{ua}->agent($self->{mobile}
        ? "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.198 Mobile Safari/537.36"
        : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.198 Safari/537.36"
    );

    $self->{ua}->default_header('Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
    $self->{ua}->default_header('Accept-Language' => 'en-US,en;q=0.5');
    $self->{ua}->default_header('Connection' => 'keep-alive');

    return $self;
}

sub fetch {
    my ($self) = @_;
    my $url = $self->{url};

    my $parsed_url = URI->new($url);
    if ($parsed_url->scheme ne 'https') {
        print "⚠️  URL is not HTTPS: $url\n";
    }

    my $res = $self->{ua}->get($url);
    die "Failed to fetch $url: " . $res->status_line unless $res->is_success;

    $self->{final_url} = $res->request->uri->as_string;
    my $html = decode('utf-8', $res->decoded_content);

    my $tree = HTML::TreeBuilder->new;
    $tree->parse($html);
    $tree->eof;
    $self->{tree} = $tree;

    my $base_tag = $tree->look_down(_tag => 'base');
    $self->{base_uri} = ($base_tag && $base_tag->attr('href'))
        ? URI->new_abs($base_tag->attr('href'), $self->{final_url})
        : URI->new($self->{final_url});
}

sub phase_1_2_checks {
    my ($self) = @_;
    my $tree = $self->{tree};
    my $base_uri = $self->{base_uri};
    my $url = $self->{final_url};

    # Title
    if (my $title = $tree->look_down(_tag => 'title')) {
        my $text = $title->as_text;
        print "✅ Title found (" . length($text) . " chars): $text\n";
        print "⚠️  Title too long (> 60 chars)\n" if length($text) > 60;
    } else {
        print "❌ No <title> tag found\n";
    }

    # Meta description
    if (my $meta = $tree->look_down(_tag => 'meta', name => 'description')) {
        my $desc = $meta->attr('content') || '';
        print "✅ Meta description (" . length($desc) . " chars): $desc\n";
        print "⚠️  Meta description too long (> 160 chars)\n" if length($desc) > 160;
    } else {
        print "❌ No meta description tag found\n";
    }

    # H1 tags
    my @h1s = $tree->look_down(_tag => 'h1');
    if (@h1s) {
        print "✅ Found " . scalar(@h1s) . " <h1> tag(s)\n";
        print "⚠️  More than one <h1> tag found\n" if @h1s > 1;
    } else {
        print "❌ No <h1> tag found\n";
    }

    # Image alt tags
    my @imgs = $tree->look_down(_tag => 'img');
    my $missing_alt = grep { !defined($_->attr('alt')) || $_->attr('alt') eq '' } @imgs;
    print "🖼️  Found " . scalar(@imgs) . " image(s)\n";
    print "⚠️  $missing_alt image(s) missing alt attributes\n" if $missing_alt;

    # Anchor tags without text
    my @links = $tree->look_down(_tag => 'a');
    my $empty_anchors = grep { $_->as_text =~ /^\s*$/ } @links;
    print "🔗 Found " . scalar(@links) . " link(s)\n";
    print "⚠️  $empty_anchors link(s) with empty or no anchor text\n" if $empty_anchors;

    # Canonical tag
    my @canonicals = $tree->look_down(_tag => 'link', rel => 'canonical');
    if (!@canonicals) {
        print "❌ No canonical <link rel=\"canonical\"> tag found\n";
        my $suggested = $base_uri->clone;
        $suggested->query(undef);
        my $host = $suggested->host;
        $host =~ s/^www\.//;
        $suggested->host($host);
        print "💡 Suggested canonical: $suggested\n";
    } elsif (scalar(@canonicals) > 1) {
        print "⚠️  Multiple canonical tags found\n";
        for (@canonicals) {
            print " - ", ($_->attr('href') // '[missing href]'), "\n";
        }
    } else {
        my $href = $canonicals[0]->attr('href');
        if ($href) {
            my $abs = URI->new_abs($href, $base_uri);
            print "✅ Canonical URL: $abs\n";
        } else {
            print "⚠️  Canonical tag present but missing href\n";
        }
    }

    # Meta robots tag
    if (my $robots = $tree->look_down(_tag => 'meta', name => 'robots')) {
        my $content = lc($robots->attr('content') || '');
        print "🤖 Meta robots: $content\n";
        print "⚠️  Robots meta discourages indexing\n" if $content =~ /noindex|nofollow/;
    } else {
        print "⚠️  No meta robots tag found (defaults may apply)\n";
    }

    # Viewport tag (mobile-friendly)
    if (my $viewport = $tree->look_down(_tag => 'meta', name => 'viewport')) {
        my $content = $viewport->attr('content') || '';
        print "📱 Viewport meta found: $content\n";
        print "⚠️  Viewport tag lacks width/device scaling\n" unless $content =~ /width\s*=\s*device-width/i;
    } else {
        print "❌ No viewport meta tag found\n";
    }

    # Structured Data
    my @jsonld = $tree->look_down(_tag => 'script', type => 'application/ld+json');
    my $has_structured_data = 0;
    for my $s (@jsonld) {
        my $json = eval { decode_json($s->as_text) };
        if ($json && ref($json) eq 'HASH' && $json->{'@context'} && $json->{'@context'} =~ /schema\.org/) {
            $has_structured_data++;
        }
    }
    my @microdata = $tree->look_down(sub {
        $_[0]->attr('itemscope') && $_[0]->attr('itemtype')
    });
    print "🧩 Found $has_structured_data JSON-LD script(s)\n" if $has_structured_data;
    print "🧩 Found " . scalar(@microdata) . " microdata block(s)\n" if @microdata;
    print "⚠️  No structured data found\n" unless $has_structured_data || @microdata;

    # Performance hints
    my @scripts = $tree->look_down(_tag => 'script');
    my @inline_scripts = grep { !$_->attr('src') } @scripts;
    print "📜 Found " . scalar(@scripts) . " script(s), " . scalar(@inline_scripts) . " inline\n";
    print "⚠️  Excessive inline scripts\n" if @inline_scripts > 3;

    my @styles = $tree->look_down(_tag => 'style');
    print "🎨 Found " . scalar(@styles) . " inline style block(s)\n";
    print "⚠️  Inline styles may reduce maintainability\n" if @styles;
}

sub phase_3_checks {
    my ($self) = @_;
    my $tree = $self->{tree};
    my $keyword = $self->{keyword};

    # Header hierarchy check
    my @headers = $tree->look_down(_tag => qr/^h[1-6]$/);
    if (@headers) {
        my @levels = map { $_->tag =~ /h([1-6])/ ? $1 : 0 } @headers;
        my $prev = 0;
        my $skipped = 0;
        for my $lvl (@levels) {
            if ($prev && $lvl > $prev + 1) {
                $skipped++;
            }
            $prev = $lvl;
        }
        if ($skipped) {
            print "⚠️  Header hierarchy issue: skipped levels detected ($skipped times)\n";
        } else {
            print "✅ Header hierarchy looks good\n";
        }
    } else {
        print "❌ No headers (h1-h6) found\n";
    }

    # Word count
    my $text = $tree->as_text;
    $text =~ s/\s+/ /g;
    my @words = split /\s+/, $text;
    my $word_count = scalar @words;
    print "📝 Word count: $word_count words\n";
    print "⚠️  Low word count (<300 words) may hurt SEO\n" if $word_count < 300;

    # Keyword usage
    if ($keyword) {
        my $keyword_count = 0;

        # Title
        if (my $title = $tree->look_down(_tag => 'title')) {
            $keyword_count += () = lc($title->as_text) =~ /\Q$keyword\E/g;
        }

        # Meta description
        if (my $meta = $tree->look_down(_tag => 'meta', name => 'description')) {
            $keyword_count += () = lc($meta->attr('content') // '') =~ /\Q$keyword\E/g;
        }

        # H1 tags
        for my $h1 (@{$tree->look_down(_tag => 'h1') || []}) {
            $keyword_count += () = lc($h1->as_text) =~ /\Q$keyword\E/g;
        }

        # Body text
        $keyword_count += () = lc($text) =~ /\Q$keyword\E/g;

        print "🔍 Keyword '$keyword' found $keyword_count time(s) on page\n";
        print "⚠️  Keyword not found on page\n" if $keyword_count == 0;
    }

    # <html lang="...">
    my $html_tag = $tree->look_down(_tag => 'html');
    if ($html_tag && $html_tag->attr('lang')) {
        print "🌐 <html> tag lang attribute: " . $html_tag->attr('lang') . "\n";
    } else {
        print "⚠️  Missing <html lang=\"...\"> attribute\n";
    }

    # Inline styles and scripts warnings
    my @inline_styles = $tree->look_down(_tag => 'style');
    print "🎨 Inline styles found: " . scalar(@inline_styles) . "\n";
    print "⚠️  Inline styles can impact maintainability\n" if @inline_styles;

    my @scripts = $tree->look_down(_tag => 'script');
    my @inline_scripts = grep { !$_->attr('src') } @scripts;
    print "📜 Scripts found: " . scalar(@scripts) . ", inline scripts: " . scalar(@inline_scripts) . "\n";
    print "⚠️  Excessive inline scripts (>3) may affect performance\n" if scalar(@inline_scripts) > 3;
}

    # URL HEAD check helper
sub _url_ok {
    my ($self, $link) = @_;

    return 0 unless $link;
    return 1 if $link =~ /^#/;
    return 1 if $link =~ /^javascript:/i;

    my $head_req = HTTP::Request->new(HEAD => $link);
    my $res = try {
        $self->{ua}->request($head_req, timeout => 5);
    } catch {
        undef;
    };
    unless ($res) {
        print "⚠️  Request failed for $link\n";
        return 0;
    }

    if ($res->is_success) {
        return 1;
    }
    elsif ($res->code == 301 || $res->code == 302) {
        print "⚠️  URL $link returns redirect (" . $res->code . "), considered broken\n";
        return 0;
    }
    else {
        print "⚠️  URL $link returns status " . $res->code . ", considered broken\n";
        return 0;
    }
}

sub phase_4_checks {
    my ($self) = @_;
    my $tree = $self->{tree};
    my $base_uri = $self->{base_uri};
    my $ua = $self->{ua};

    print "\n🔍 Checking images and links for broken references (this may take a while)...\n";

    my $broken_images = 0;
    my $broken_links  = 0;

    # Check images
    my @imgs = $tree->look_down(_tag => 'img');
    for my $img (@imgs) {
        my $src = $img->attr('src');
        my $abs = URI->new_abs($src, $base_uri);
        unless ($self->_url_ok($abs)) {
            print "❌ Broken image: $abs\n";
            $broken_images++;
        }
    }
    print "⚠️  $broken_images broken image(s) found\n" if $broken_images;

    # Check links
    my @links = $tree->look_down(_tag => 'a');
    for my $link (@links) {
        my $href = $link->attr('href');
        my $abs = $href ? URI->new_abs($href, $base_uri) : undef;
        unless ($href && $self->_url_ok($abs)) {
            print "❌ Broken link: $abs\n" if $href;
            $broken_links++;
        }
    }
    print "⚠️  $broken_links broken link(s) found\n" if $broken_links;

    # Vague link text
    my @vague_texts = qw(click here read more more info link here);
    my $vague_count = 0;
    for my $link (@links) {
        my $text = lc $link->as_text;
        for my $vague (@vague_texts) {
            if ($text eq $vague) {
                print "⚠️  Vague link text: '$text'\n";
                $vague_count++;
                last;
            }
        }
    }
    print "⚠️  $vague_count vague link text(s) found\n" if $vague_count;

    # robots.txt check
    print "\n🌐 Checking robots.txt and sitemap.xml...\n";
    my $robots_url = $base_uri->clone;
    $robots_url->path('/robots.txt');
    my $robots_res = $ua->get($robots_url);
    if ($robots_res->is_success) {
        print "✅ robots.txt found at $robots_url\n";
        if ($robots_res->decoded_content =~ /Sitemap:\s*(\S+)/i) {
            my $sitemap_url = $1;
            print "🗺️  Sitemap declared in robots.txt: $sitemap_url\n";
        } else {
            print "⚠️  No Sitemap directive found in robots.txt\n";
        }
    } else {
        print "❌ robots.txt not found at $robots_url\n";
    }

    # sitemap.xml check
    my $sitemap_url = $base_uri->clone;
    $sitemap_url->path('/sitemap.xml');
    my $sitemap_res = $ua->get($sitemap_url);
    if ($sitemap_res->is_success) {
        print "✅ sitemap.xml found at $sitemap_url\n";
        if ($sitemap_res->decoded_content =~ /<urlset/i) {
            print "✅ sitemap.xml root node <urlset> found\n";
        } else {
            print "⚠️  sitemap.xml missing <urlset> root node\n";
        }
    } else {
        print "❌ sitemap.xml not found at $sitemap_url\n";
    }
}

sub run_all {
    my ($self) = @_;
    $self->fetch;
    $self->phase_1_2_checks;
    $self->phase_3_checks;
    $self->phase_4_checks;
}

1;
