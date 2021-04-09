# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2020 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

ProductOpener::MainCountries - determine the main countries a product is sold in

=head1 SYNOPSIS


=head1 DESCRIPTION

Products on Open Food Facts have a countries_tags field that list the countries
where a product is sold. The information is entered by users, food producers,
and additional countries are added by the scanbot.pl script if a product
is scanned by 5 or more different IP addresses in a specific country.

In some cases, products may be marked as sold in a country even it is not widely
sold in that country. For instance, a lot of discount shops import products that
are intended for sale to other countries. Scan data can be tricky as well:
people who live close to a border often shop in another country, and they
may scan products when they are back in their home country.

This module tries to determine which countries a product is "mostly" sold in.

The determination can be made on different factors:
- scan data
- languages
- brands
- etc.

=cut

package ProductOpener::MainCountries;

use utf8;
use Modern::Perl '2017';
use Exporter    qw< import >;

use Log::Any qw($log);

BEGIN
{
	use vars       qw(@ISA @EXPORT_OK %EXPORT_TAGS);
	@EXPORT_OK = qw(

		&load_scans_data
		&compute_main_countries

		);    # symbols to export on request
	%EXPORT_TAGS = (all => [@EXPORT_OK]);
}

use vars @EXPORT_OK ;

use ProductOpener::Config qw/:all/;
use ProductOpener::Tags qw/:all/;
use ProductOpener::Store qw/:all/;
use ProductOpener::Products qw/:all/;


=head1 FUNCTIONS

=head2 load_scans_data()

Loads scans data agregated by country from the products/all_products_scans.json
file generated by scanbot.pl

=cut

my $all_products_scans_ref;

sub load_scans_data() {
	
	$all_products_scans_ref = retrieve_json("$data_root/products/all_products_scans.json");
}


=head2 compute_main_countries ( $product_ref )

=head3 Arguments

=head4 Product reference $product_ref

=head3 Return values


=cut

sub compute_main_countries($) {

	my $product_ref = shift;
	
	$product_ref->{main_countries_tags} = [];
	$product_ref->{removed_countries_tags} = [];
	$product_ref->{added_countries_tags} = [];
	
	# Remove existing misc tags related to main_countries
	if (defined $product_ref->{misc_tags}) {
		my @misc_tags = ();
		foreach my $tag (@{$product_ref->{misc_tags}}) {
			if ($tag !~ /main-countries/) {
				push @misc_tags, $tag;
			}
		}
		$product_ref->{misc_tags} = \@misc_tags;
	}

	# Load the scan data
	my $path = product_path($product_ref);
	my $scans_ref = retrieve_json("$data_root/products/$path/scans.json");
	
	if (defined $scans_ref) {
	
		# Use the latest available year
		my $year = 2030;
		while (not exists $scans_ref->{$year}) {
			$year--;
		}
		if (exists $scans_ref->{$year}) {
		
			# Check if some of the countries in countries_tags should be removed based on scan data
			if (defined $product_ref->{countries_tags}) {
				foreach my $country_tag (@{$product_ref->{countries_tags}}) {
					my $cc = country_to_cc($country_tag);
					next if not defined $cc;
					next if $cc eq "world";
					
					# Compare the country scans ratio to the world scans for the product
					# with the average ratio across all products
					
					my $average_cc_to_world_scans_ratio = $all_products_scans_ref->{$year}{unique_scans_n_by_country}{$cc}
						/ $all_products_scans_ref->{$year}{unique_scans_n_by_country}{"world"};
					my $cc_to_world_scans_ratio = ($scans_ref->{$year}{unique_scans_n_by_country}{$cc} || 0)
						/ $scans_ref->{$year}{unique_scans_n_by_country}{"world"};
						
					# Check if the product has data in one of the languages of the country
					my $data_in_country_language = 0;
					my $product_name_in_country_language = 0;
					
					foreach my $country_language (@{$country_languages{$cc}}) {
						foreach my $field ("product_name", "generic_name", "ingredients_text") {
							if ((defined $product_ref->{$field . "_" . $country_language})
								and ($product_ref->{$field . "_" . $country_language} ne "")) {
								$data_in_country_language++;
								if ($field eq "product_name") {
									$product_name_in_country_language++;
								}
							}
						}
					}						
						
					$log->debug("compute_main_countries - scan data for country", { code => $product_ref->{code},
							country_tag => $country_tag, cc => $cc, year => $year,
							all_products_scans_cc => $all_products_scans_ref->{$year}{unique_scans_n_by_country}{$cc},
							all_products_scans_world => $all_products_scans_ref->{$year}{unique_scans_n_by_country}{"world"},
							scans_cc => $scans_ref->{$year}{unique_scans_n_by_country}{$cc},
							scans_world => $scans_ref->{$year}{unique_scans_n_by_country}{"world"},
							scans_ref => $scans_ref->{$year},
							cc_to_world_scans_ratio => $cc_to_world_scans_ratio,
							average_cc_to_world_scans_ratio => $average_cc_to_world_scans_ratio,
							data_in_country_language => $data_in_country_language,
							  } ) if $log->is_debug();						
					
					# More than 10 scans, and a scan ratio for the country < 10% of the average scan ratio
					if (($scans_ref->{$year}{unique_scans_n_by_country}{"world"} >= 10)
						and ($cc_to_world_scans_ratio <= 0.3 * $average_cc_to_world_scans_ratio)) {
						
						$log->debug("compute_main_countries - low scan ratio for country", { code => $product_ref->{code}, cc => $cc,
							cc_to_world_scans_ratio => $cc_to_world_scans_ratio,
							average_cc_to_world_scans_ratio => $average_cc_to_world_scans_ratio,
							scans_ref => $scans_ref,
							data_in_country_language => $data_in_country_language,
							  } ) if $log->is_debug();
							  
						defined $product_ref->{misc_tags} or $product_ref->{misc_tags} = [];
						push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-unexpectedly-low-scans";
						
						if ($cc_to_world_scans_ratio <= 0.1 * $average_cc_to_world_scans_ratio) {
							push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-unexpectedly-low-scans-0-10-percent-of-expected";
						}
						elsif ($cc_to_world_scans_ratio <= 0.2 * $average_cc_to_world_scans_ratio) {
							push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-unexpectedly-low-scans-10-20-percent-of-expected";
						}
						elsif ($cc_to_world_scans_ratio <= 0.3 * $average_cc_to_world_scans_ratio) {
							push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-unexpectedly-low-scans-20-30-percent-of-expected";
						}
						
						if ($data_in_country_language < 1) {
							push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-unexpectedly-low-scans-and-no-data-in-country-language";
						}
						elsif ($data_in_country_language == 1) {
							push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-unexpectedly-low-scans-and-only-1-field-in-country-language";
						}
					}
					
					if ($product_name_in_country_language < 1) {
						defined $product_ref->{misc_tags} or $product_ref->{misc_tags} = [];
						push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-product-name-not-in-country-language";
					}					
					
					if ($data_in_country_language < 1) {
						defined $product_ref->{misc_tags} or $product_ref->{misc_tags} = [];
						push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-no-data-in-country-language";
					}
					elsif ($data_in_country_language == 1) {
						defined $product_ref->{misc_tags} or $product_ref->{misc_tags} = [];
						push @{$product_ref->{misc_tags}}, "en:main-countries-$cc-only-1-field-in-country-language";
					}
				}
			}
		}
		
		my $most_recent_year = 2020;
		
		if (not exists $scans_ref->{$most_recent_year}) {
			push @{$product_ref->{misc_tags}}, "en:main-countries-old-product-without-scans-in-$most_recent_year";
		}
	}
	else {
		if ($product_ref->{created_t} < 1609462800) {	# 2021-01-01
			push @{$product_ref->{misc_tags}}, "en:main-countries-no-scans";
		}
		else {
			push @{$product_ref->{misc_tags}}, "en:main-countries-new-product";
		}
	}
}

1;

