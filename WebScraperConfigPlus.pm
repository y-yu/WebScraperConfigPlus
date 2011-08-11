package WebScraperConfigPlus;

use Web::Scraper;
use Config::Any;
use Data::Visitor::Callback;
use URI;
use HTTP::Response;
use HTML::Tree;

sub new
{
	my $class    = shift;
	my $self     = bless {}, $class;
	my $settings = shift;

	$settings = $self->_load_config($settings);

	my $config      = ([grep { $_->{scraper} } @$settings])[0];
	my $subroutines = ([grep { $_->{subroutine} } @$settings])[0];

	{
		my $v = Data::Visitor::Callback->new(
			hash => sub {
				my ($visitor, $data) = @_;
				
				my ($key) = keys %$data;
				if ($key eq 'sub') {
					$data = eval $data->{$key};
				}

				return $data;
			},
		);
		$config = $v->visit($config);

		$v = Data::Visitor::Callback->new(
			hash => sub {
				my ($visitor, $data) = @_;
				
				for (keys %$data) {
					$data->{$_} = eval $data->{$_} if ($_ eq 'before' || $_ eq 'after');
				}

				return $data;
			}
		);
		$subroutines = $v->visit($subroutines);
	}

	if (@$config - @$subroutines > 1) {
		die 'requre more subroutines';
	}

	$self->{config}	     = $config;
	$self->{subroutines} = $subroutines;

	return $self;
}

sub _load_config
{
	my $self = shift;
	my $file = shift;

	if (ref $file eq 'HASH') {
		return $file;
	} else {
		my $list = Config::Any->load_files({files => [ $file ], use_ext => 1});
		if (! @$list ) {
			require Carp;
			Carp::croak("Could not load config file $file: $@");
		}

		return (values %{$list->[0]})[0];
	}
}

sub scrape
{
	my $self   = shift;
	my $result = \@_; 

	my $config      = $self->{config};
	my $subroutines = $self->{subroutines};

	for (@$config) {
		my $sub = (@$subroutines ? (shift @$subroutines)->{'subroutine'} : undef);

		$result = $self->_scraping($_, $sub, $result);
	}

	return \$result;
}

sub _scraping 
{
	my $self = shift;
	my ($config, $subroutine, $source) = @_;

	my $scrape_args;
	if ($subroutine->{before}) {
		$scrape_args = $subroutine->{before}->($source) 
	} else {
		$scrape_args->[0]->{url}  = pop @$source;
		$scrape_args->[0]->{lest} = $source;
	}

	my $scraper = $self->_recurse($config)->();

	my @scrape;
	for my $arg (@$scrape_args) {
		$arg->{url}  = URI->new($arg->{url}) if (!ref $arg->{url});
		$arg->{lest} = [] if (!$arg->{lest});

		push @scrape, $scraper->scrape($arg->{url}, @{$arg->{lest}});
	}

	my $result;
	if ($subroutine->{after}) {
		$result = $subroutine->{after}->( \@scrape );
	} else {
		$result = \@scrape;
	}

	return $result;
}

sub _recurse
{
	my ($self, $rules) = @_;

	my $ref = ref($rules);
	my $ret;
	if (! $ref) {
		$ret = $rules;
	} elsif ($ref eq 'ARRAY') {
		my @elements;
		foreach my $rule (@$rules) {
			if ( ref($rule) eq 'CODE' ) {
				push @elements, $rule;
			} else {
				push @elements, ref $rule ? $self->_recurse($rule) : $rule;
			}
		}

		$ret = \@elements;
	} elsif ($ref eq 'HASH') {
		my ($op)    = keys %$rules;
		my $h       = $self->_recurse($rules->{$op});
		my $is_func = ($op =~ /^(?:scraper|process(?:_first)?|result)$/);

		if ($is_func) {
			my @args = (ref $h eq 'ARRAY') ? @$h : ($h);
			if ($op eq 'scraper') {
				$ret = sub { 
					scraper(sub { for (@args) { $_->() } })
				};
			} else {
				$ret = sub {
					my $code = sub {
						@_ = map { (ref $_ eq 'CODE') ? $_->() : $_ } @args;
						goto &$op;
					};
					$code->()
				};
			}
		} else {
			$ret = { $op => $h };
		}
	} else {
		require Data::Dumper;
		die "Web::Scraper::Config does not know how to parse: " . Data::Dumper::Dumper($rules);
	}

	return $ret;
}

1;

