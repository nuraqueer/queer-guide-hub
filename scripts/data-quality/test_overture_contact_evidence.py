import copy
import importlib.util
import pathlib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('overture', pathlib.Path(__file__).with_name('collect-overture-contact-evidence.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ContactEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.venue = dict(name='B2 Hotel Zürich', city_name='Zurich', country_code='CH', latitude=47.36, longitude=8.53, address='Brandschenkestrasse 152')
        self.place = dict(id='real-source-id', names={'primary': 'B2 Hotel Zurich'}, latitude=47.36, longitude=8.53,
                          addresses=[dict(country='CH', freeform='Brandschenkestrasse 152')], confidence=.99,
                          operating_status='open', websites=['https://www.b2hotel.ch/'], sources=[dict(license='CDLA-Permissive-2.0')])

    def test_corroborated_unique_identity(self):
        self.assertEqual(module.positive_match(self.venue, [self.place], True), self.place)

    def test_truncated_window_never_establishes_uniqueness(self):
        self.assertIsNone(module.positive_match(self.venue, [self.place], False))

    def test_second_closed_or_contactless_namesake_still_blocks(self):
        for overrides in [dict(operating_status='closed'), dict(websites=[]), dict(confidence=.1)]:
            other = {**self.place, **overrides, 'id': 'another-record'}
            self.assertIsNone(module.positive_match(self.venue, [self.place, other], True))

    def test_country_address_and_distance_must_all_agree(self):
        for overrides in [dict(addresses=[dict(country='DE', freeform=self.venue['address'])]),
                          dict(addresses=[dict(country='CH', freeform='Otherstrasse 152')]), dict(latitude=47.38)]:
            self.assertIsNone(module.positive_match(self.venue, [{**self.place, **overrides}], True))

    def test_address_numbers_are_complete_tokens(self):
        other = copy.deepcopy(self.place)
        other['addresses'][0]['freeform'] = 'Brandschenkestrasse 1520'
        self.assertFalse(module.identity_matches(self.venue, other))

    def test_unknown_closed_low_confidence_or_missing_license_is_not_positive(self):
        for overrides in [dict(operating_status=None), dict(operating_status='closed'), dict(confidence=.8),
                          dict(sources=[]), dict(sources=[dict(license='unknown')])]:
            self.assertIsNone(module.positive_match(self.venue, [{**self.place, **overrides}], True))

    def test_distinct_websites_require_further_evidence(self):
        self.assertIsNone(module.positive_match(self.venue, [{**self.place, 'websites': ['https://one.example', 'https://two.example']}], True))

    def test_polar_longitude_margin_must_cover_the_matching_radius(self):
        venue = dict(latitude=80, longitude=15)
        self.assertFalse(module.window_contains_radius(venue, [14.998, 79.999, 15.002, 80.001]))
        self.assertTrue(module.window_contains_radius(venue, [14.996, 79.999, 15.004, 80.001]))

    def test_non_latin_names_are_preserved_for_identity_matching(self):
        self.assertEqual(module.normalized('ホテル Sunshine'), 'ホテル sunshine')
        self.assertNotEqual(module.normalized('ホテル Sunshine'), module.normalized('クラブ Sunshine'))

    def test_live_name_and_street_are_both_required(self):
        for title, body, expected in [
            ('B2 Boutique Hotel Zurich', '<p>Brandschenkestrasse 152</p>', (True, True)),
            ('Unrelated Casino', '<p>Brandschenkestrasse 152</p>', (False, True)),
            ('B2 Boutique Hotel Zurich', '<p>Another street 152</p>', (True, False)),
        ]:
            identity = module.website_identity(self.venue, self.place, title, body)
            self.assertEqual((identity['name_match'], identity['street_match']), expected)

    def test_reused_brand_word_with_a_different_address_is_insufficient(self):
        venue = dict(name='Myriad Gastropub', city_name='San Francisco', country_code='US', address='2491 Mission Street')
        place = dict(addresses=[dict(country='US', freeform='2491 Mission St')])
        result = module.website_identity(venue, place, 'Myriad Hospitality Solutions', '<p>1300 Other Avenue</p>')
        self.assertTrue(result['name_match'])
        self.assertFalse(result['street_match'])

    def test_contact_links_stay_on_the_identified_host_and_are_bounded(self):
        html = """<a href="/contact">Contact</a><a href="/contact#team">Team</a>
        <a href="https://www.example.test/impressum">Legal</a>
        <a href="https://elsewhere.test/contact">Elsewhere</a>
        <a href="https://user:password@example.test/contact">Credentials</a>
        <a href="mailto:person@example.test">Mail</a><a href="javascript:contact()">Script</a>
        <a href="/about">About</a><a href="/locations">Locations</a>"""
        self.assertEqual(module.contact_page_urls('https://example.test/', html),
                         ['https://example.test/contact', 'https://www.example.test/impressum', 'https://example.test/about'])

    def probe_fixture(self, root_title, contact_address, contact_link='/contact'):
        calls = []
        root = f'<title>{root_title}</title><a href="{contact_link}">Contact</a>' + 'x' * 2100
        contact = f'<title>Contact</title><p>{contact_address}</p>' + 'x' * 2100

        class Response:
            status = 200
            headers = {'Content-Type': 'text/html'}

            def __init__(self, url, text):
                self.url, self.body = url, text.encode()

            def read(self, limit):
                return self.body[:limit]

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        class Opener:
            def open(self, request, timeout):
                calls.append(request.full_url)
                if request.full_url == 'https://example.test/':
                    return Response(request.full_url, root)
                if request.full_url == 'https://example.test/contact':
                    return Response(request.full_url, contact)
                raise AssertionError('Unexpected request')

        with patch.object(module, 'safe_url', side_effect=lambda value: value), \
                patch.object(module.urllib.request, 'build_opener', return_value=Opener()):
            result = module.website_probe('https://example.test/', self.venue, self.place)
        return result, calls

    def test_same_host_contact_address_and_real_homepage_brand_can_corroborate(self):
        result, calls = self.probe_fixture('B2 Boutique Hotel Zurich', self.venue['address'])
        self.assertTrue(result['usable'])
        self.assertEqual(calls, ['https://example.test/', 'https://example.test/contact'])
        self.assertEqual(result['title'], 'Contact')
        self.assertEqual(result['identity']['brand_title'], 'B2 Boutique Hotel Zurich')
        self.assertEqual(result['identity']['brand_source_url'], 'https://example.test/')
        self.assertNotEqual(result['prefix_sha256'], result['site_root_probe']['prefix_sha256'])

    def test_unrelated_root_brand_cannot_be_rescued_by_a_contact_page(self):
        result, calls = self.probe_fixture('Unrelated Casino', self.venue['address'])
        self.assertFalse(result['usable'])
        self.assertEqual(calls, ['https://example.test/'])

    def test_contact_address_must_still_be_the_exact_business_location(self):
        result, _ = self.probe_fixture('B2 Boutique Hotel Zurich', 'Another street 152')
        self.assertFalse(result['usable'])

    def test_external_contact_page_cannot_establish_business_identity(self):
        result, calls = self.probe_fixture('B2 Boutique Hotel Zurich', self.venue['address'], 'https://elsewhere.test/contact')
        self.assertFalse(result['usable'])
        self.assertEqual(calls, ['https://example.test/'])

    def test_street_ownership_does_not_require_source_city_state_postal_formatting(self):
        venue = dict(name='The Ave Bar', city_name='San Francisco', country_code='US', address='1607 Ocean Ave')
        place = dict(addresses=[dict(country='US', freeform='1607 Ocean Ave, San Francisco, California')])
        result = module.website_identity(venue, place, 'The Ave Bar', '<p>1607 Ocean Avenue, San Francisco CA 94112</p>')
        self.assertTrue(result['name_match'])
        self.assertTrue(result['street_match'])
        self.assertEqual(result['street_address'], '1607 Ocean Ave')
        self.assertFalse(module.website_identity(venue, place, 'The Ave Bar', '<p>16070 Ocean Avenue, San Francisco</p>')['street_match'])

    def test_city_or_suite_without_a_street_does_not_confirm_website_identity(self):
        venue = dict(name='Example Hotel', city_name='San Francisco', country_code='US', address=None)
        for address in ['San Francisco, CA 94112', 'Suite 123', 'PO Box 123']:
            place = dict(addresses=[dict(country='US', freeform=address)])
            self.assertFalse(module.website_identity(venue, place, 'Example Hotel', '<p>' + address + '</p>')['street_match'])


if __name__ == '__main__':
    unittest.main()
