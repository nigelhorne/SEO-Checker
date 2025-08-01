package SEO::Checker;
use strict;
use warnings;
use LWP::UserAgent;
use LWP::Parallel::UserAgent;
use HTML::TreeBuilder;
use URI;
use JSON qw(decode_json);
use Encode qw(decode);
use HTTP::Request;
use Try::Tiny;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::Utils qw(fmap);

# use LWP::Debug qw(+);

sub new {
	my ($class, %args) = @_;
	$args{parallel} = 0;
	my $self = bless {
		# url	 => $args{url},
		mobile => $args{mobile} // 0,
		# keyword => $args{keyword},
		tree	=> undef,
		final_url => undef,
		base_uri => undef,
	%args
	}, $class;

	if($args{parallel}) {
		$self->{ua} = LWP::Parallel::UserAgent->new();
		# $self->{ua}->nonblock(0);
		$self->{ua}->timeout(10);
		$self->{ua}->redirect(1);
		# $self->{ua}->ssl_opts(verify_hostname => 0);	# prevent "Can't connect to geocode.xyz:443 (certificate verify failed)"
	} else {
		$self->{ua} = LWP::UserAgent->new();
	}

	$self->{ua_string} = $self->{mobile}
		? "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.198 Mobile Safari/537.36"
		: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.198 Safari/537.36"
	;
	$self->{ua}->agent($self->{mobile}
		? "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.198 Mobile Safari/537.36"
		: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.198 Safari/537.36"
	);

	$self->{ua}->default_header('Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
	$self->{ua}->default_header('Accept-Language' => 'en-US,en;q=0.5');
	$self->{ua}->default_header('Connection' => 'keep-alive');
	$self->{ua}->timeout(5);

	return bless $self, $class;
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

# Private method: parallel URL check using LWP::Parallel::UserAgent
sub _check_urls_parallel {
	my ($self, $urls) = @_;

	my @urls = @{$urls};

	my $pua = $self->{'ua'};

	my %results;

	my %reqmap;
	for my $url (@urls) {
		next unless $url && !ref($url);  # skip if undefined or a reference
		my $req = HTTP::Request->new('GET', $url);
		if(my $res = $pua->register($req)) {
			die $res->error_as_HTML();
		}

		$reqmap{$url} = $req;
	}

	$pua->max_hosts(scalar(@{$urls}) + 1);
	my $entries = $pua->wait(20);

	my %responses;
	foreach (keys %$entries) {
		my $res = $entries->{$_}->response;

		# response is of type HTTP::Response

		my $url = $res->request->url();

		if ($res->is_success) {
			$results{$url} = { success => 1, code => $res->code, message => "OK" };
		}
		elsif ($res->code == 301 || $res->code == 302) {
			# print "⚠️  URL $url redirects with status " . $res->code . "\n";
			$results{$url} = { success => 0, code => $res->code, message => "Redirect" };
		}
		else {
			# print "⚠️  URL $url returns status " . $res->code . "\n";
			$results{$url} = { success => 0, code => $res->code, message => $res->status_line };
		}
	}

	return \%results;
}

sub _new_check_urls_parallel {
    my ($self, $urls) = @_;

    my $loop = IO::Async::Loop->new;

    my $http = Net::Async::HTTP->new(
        max_connections_per_host => 4,
        user_agent => $self->{ua_string} || 'SEO::Checker',
    );

print join(';', @{$urls}), "\n";
    $loop->add($http);

    my $futures = fmap {
        my $url = shift;

        $http->GET($url)->then(sub {
            my ($response) = @_;
            my $code = $response->code;
            my $message = $response->message;

            Future->done({
                url     => $url,
                code    => $code,
                success => ($code >= 200 && $code < 300) ? 1 : 0,
                message => $message,
            });
        })->catch(sub {
            my ($err) = @_;
            Future->done({
                url     => $url,
                code    => 0,
                success => 0,
                message => $err || 'Request failed',
            });
        });

    } foreach => $urls, concurrent => 10;

 # Wrap the future in a timeout
    Future::Utils::timeout($futures, 10, "Timed out");

    print __LINE__, "\n";
    my @results = $loop->await($futures);
    print __LINE__, "\n";
    return \@results;
}


sub _check_url {
	my ($self, $url) = @_;
	my $ua = $self->{ua};

	# Create a HEAD request for efficiency
	my $req = HTTP::Request->new(HEAD => $url);

	# Explicitly set headers to mimic a browser
	$req->header('User-Agent'	=> $self->{ua}->agent);
	$req->header('Accept'		=> 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
	$req->header('Accept-Language' => 'en-US,en;q=0.9');

	my $res = $ua->request($req);

	# If no response, return failure
	unless ($res) {
		return { success => 0, code => 0, message => 'No response' };
	}

	# Warn and return failure on redirects (301/302)
	if ($res->code == 301 || $res->code == 302) {
		warn "⚠️  URL $url redirects to " . $res->header('Location') . "\n";
		return { success => 0, code => $res->code, message => 'Redirect' };
	}

	# Check for success
	if ($res->is_success) {
		return { success => 1, code => $res->code, message => 'OK' };
	} else {
		return { success => 0, code => $res->code, message => $res->status_line };
	}
}

sub phase_4_checks {
	my ($self) = @_;
	my $tree = $self->{tree};
	my $base_uri = $self->{base_uri};

	my @imgs = $tree->look_down(_tag => 'img');
	my @links = $tree->look_down(_tag => 'a');

	# Gather absolute URLs for images and links
	my @img_urls = map { URI->new_abs($_->attr('src'), $base_uri)->as_string } grep { $_->attr('src') } @imgs;
	my @link_urls = map { URI->new_abs($_->attr('href'), $base_uri)->as_string } grep { $_->attr('href') } @links;

	if($self->{parallel}) {
		print "🔍 Checking " . scalar(@img_urls) . " images and " . scalar(@link_urls) . " links in parallel...\n";
	my $img_results = $self->_check_urls_parallel(\@img_urls);
	my $link_results = $self->_check_urls_parallel(\@link_urls);

	# Report broken/redirect images
	my $broken_images = 0;
	for my $url (@img_urls) {
		my $res = $img_results->{$url};
		next if $res->{success};
		$broken_images++;
if ($res) {
	print "❌ Image URL broken or redirected: $url (Status: " .
		  ($res->{code} // 'N/A') . " - " .
		  ($res->{message} // 'N/A') . ")\n";
} else {
	print "❌ Image URL broken or redirected: $url (Status: No response)\n";
}
	
	}
	print "⚠️  $broken_images broken or redirected image(s) found\n" if $broken_images;

	# Report broken/redirect links
	my $broken_links = 0;
	for my $url (@link_urls) {
		my $res = $link_results->{$url};
		next if $res->{success};
		$broken_links++;
if ($res) {
	print "❌ Link URL broken or redirected: $url (Status: " .
		  ($res->{code} // 'N/A') . " - " . ($res->{message} // 'N/A') . ")\n";
} else {
	print "❌ Link URL broken or redirected: $url (Status: No response)\n";
}
	
	}
	print "⚠️  $broken_links broken or redirected link(s) found\n" if $broken_links;
	} else {
		# !parallel
		print "🔍 Checking " . scalar(@img_urls) . " images and " . scalar(@link_urls) . " links...\n";
		foreach my $url(@img_urls) {
			my $result = $self->_check_url($url);
			if ($result->{success}) {
				print "✅ Image URL $url is fine\n";
			} else {
				print "❌ Image URL $url check failed: $result->{code} - $result->{message}\n";
			}
		}
		foreach my $url(@link_urls) {
			my $result = $self->_check_url($url);
			if ($result->{success}) {
				print "✅ Link URL $url is fine\n";
			} else {
				print "❌ Link URL $url check failed: $result->{code} - $result->{message}\n";
			}
		}
	}

	# Vague link text check
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

	# robots.txt and sitemap.xml checks
	print "\n🌐 Checking robots.txt and sitemap.xml...\n";
	my $robots_url = $base_uri->clone;
	$robots_url->path('/robots.txt');
	my $robots_res = $self->{ua}->get($robots_url);
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

	my $sitemap_url = $base_uri->clone;
	$sitemap_url->path('/sitemap.xml');
	my $sitemap_res = $self->{ua}->get($sitemap_url);
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
