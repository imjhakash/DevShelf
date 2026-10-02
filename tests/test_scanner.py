"""Exercise the compiled scanner with real directories, including false-positive traps."""
import json
import pathlib
import subprocess
import tempfile
import unittest

APP = pathlib.Path(__file__).resolve().parents[1] / "build/DevShelf.app/Contents/MacOS/DevShelf"


class ScannerTests(unittest.TestCase):
    def test_discovery_and_exclusions(self):
        with tempfile.TemporaryDirectory(prefix="devshelf-check-") as temp:
            root = pathlib.Path(temp).resolve()

            def write(name, content):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)

            write("client portal/package.json", json.dumps({
                "name": "@client/portal", "dependencies": {"next": "^15", "react": "^19"},
                "devDependencies": {"typescript": "^5", "react": "^18"}, "scripts": {"dev": "next dev"},
            }))
            write("client portal/.git/HEAD", "ref: refs/heads/main")
            write("client portal/node_modules/react/package.json", '{"name":"react","version":"19.0.0"}')
            write("client portal/packages/nested/package.json", '{"name":"nested","dependencies":{"vue":"^3"}}')
            write("client portal/public/index.html", "<title>App public folder</title>")
            write("client portal/docs/index.html", "<title>App documentation</title>")
            write("plugins/a/plugin.php", "<?php\n/*\nPlugin Name: Better Forms\nDescription: Form builder\n*/")
            write("plugins/a/package.json", '{"name":"plugin-build"}')
            write("wp-site/wp-load.php", "<?php")
            write("wp-site/wp-admin/index.php", "<?php\n// Plugin Name: Should be skipped")
            write("plain/index.html", "<!doctype html><title>Portfolio</title>")
            write("php/composer.json", '{"require":{"laravel/framework":"^12"}}')
            write("python/pyproject.toml", '[project]\nname="automation"')
            write("repo/.git/HEAD", "ref: refs/heads/main")
            write("broken/package.json", "{not json")
            write("fake/example.php", '<?php $example = "Plugin Name: Not a plugin";')
            write("vendor/skipped/package.json", '{"name":"skip"}')
            write(".cache/skipped/package.json", '{"name":"skip"}')
            (root / "linked").symlink_to(root / "client portal", target_is_directory=True)
            before = sorted(str(p.relative_to(root)) for p in root.rglob("*"))
            result = json.loads(subprocess.check_output([str(APP), "--scan-only", "--root", str(root), "--root", str(root / "client portal")]))
            projects = {pathlib.Path(p["path"]).resolve().relative_to(root).as_posix(): p for p in result["projects"]}
            self.assertEqual(len(result["projects"]), 8)
            self.assertEqual(set(projects), {"client portal", "client portal/packages/nested", "plugins/a", "wp-site", "plain", "php", "python", "repo"})
            self.assertEqual(projects["plugins/a"]["name"], "Better Forms")
            self.assertEqual(projects["plugins/a"]["kind"], "WordPress plugin")
            self.assertEqual(projects["client portal"]["framework"], "Next.js")
            self.assertEqual(projects["client portal/packages/nested"]["framework"], "Vue")
            self.assertTrue(projects["client portal"]["git"])
            self.assertTrue(projects["client portal"]["dependenciesInstalled"])
            self.assertEqual(len(projects["client portal"]["dependencies"]), 3)
            self.assertEqual(projects["php"]["framework"], "Laravel")
            self.assertEqual(projects["wp-site"]["kind"], "WordPress site")
            self.assertEqual(before, sorted(str(p.relative_to(root)) for p in root.rglob("*")))

    def test_unavailable_root_is_reported(self):
        result = json.loads(subprocess.check_output([str(APP), "--scan-only", "--root", "/this-path-does-not-exist-devshelf"]))
        self.assertEqual(result["projects"], [])
        self.assertEqual(len(result["warnings"]), 1)


if __name__ == "__main__":
    unittest.main()
