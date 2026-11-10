"""Tests for scripts/build_release.py: python3 -m unittest discover -s scripts"""

import unittest

from build_release import BuildError, check_tag, release_notes

CHANGELOG = """# Changelog

## [Unreleased]

## [1.5.0] - 2026-11-10

Intro line.

### Added
- **Thing**: it works.

## [1.4.0] - 2026-11-09

### Fixed
- Old fix.

## [1.0.0] - 2025-01-01

### Added
- First release.

[1.5.0]: https://example.org/releases/tag/v1.5.0
[1.0.0]: https://example.org/releases/tag/v1.0.0
"""


class ReleaseNotesTest(unittest.TestCase):
    def test_takes_the_entry_without_heading_or_next_entry(self):
        self.assertEqual(release_notes(CHANGELOG, "1.5.0"), "Intro line.\n\n### Added\n- **Thing**: it works.\n")

    def test_last_entry_drops_the_link_definitions(self):
        self.assertEqual(release_notes(CHANGELOG, "1.0.0"), "### Added\n- First release.\n")

    def test_version_is_matched_exactly(self):
        with self.assertRaisesRegex(BuildError, "no entry for 1.5"):
            release_notes(CHANGELOG, "1.5")

    def test_missing_entry_fails(self):
        with self.assertRaisesRegex(BuildError, "no entry for 9.9.9"):
            release_notes(CHANGELOG, "9.9.9")

    def test_empty_entry_fails(self):
        with self.assertRaisesRegex(BuildError, "entry for 2.0.0 is empty"):
            release_notes("## [2.0.0] - 2026-12-01\n\n## [1.0.0]\n- x\n", "2.0.0")


class CheckTagTest(unittest.TestCase):
    def test_newest_entry_must_be_the_version(self):
        check_tag("v1.5.0", "1.5.0", CHANGELOG)
        with self.assertRaisesRegex(BuildError, "newest CHANGELOG.md entry is 1.5.0, expected 1.6.0"):
            check_tag("v1.6.0", "1.6.0", CHANGELOG)

    def test_tag_must_match_version(self):
        with self.assertRaisesRegex(BuildError, "does not match VERSION"):
            check_tag("v1.4.0", "1.5.0", CHANGELOG)


if __name__ == "__main__":
    unittest.main()
