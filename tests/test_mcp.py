"""Drive `DevShelf --mcp` over stdio like an AI assistant would, using a throwaway data folder."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

APP = pathlib.Path(__file__).resolve().parents[1] / "build/DevShelf.app/Contents/MacOS/DevShelf"


class MCPClient:
    def __init__(self, data_dir):
        env = dict(os.environ, DEVSHELF_DATA_DIR=str(data_dir))
        self.process = subprocess.Popen([str(APP), "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.next_id = 0

    def send(self, method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            self.next_id += 1
            message["id"] = self.next_id
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        if notify:
            return None
        reply = json.loads(self.process.stdout.readline())
        assert reply["id"] == self.next_id, reply
        return reply

    def call(self, tool, **arguments):
        result = self.send("tools/call", {"name": tool, "arguments": arguments})["result"]
        text = result["content"][0]["text"]
        if result["isError"]:
            return None, text
        try:
            return json.loads(text), None
        except json.JSONDecodeError:
            return text, None

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()
        self.process.stderr.close()


class MCPServerTests(unittest.TestCase):
    def test_full_project_setup(self):
        with tempfile.TemporaryDirectory(prefix="devshelf-mcp-") as temp:
            temp = pathlib.Path(temp).resolve()
            data, shelf_root, downloads = temp / "data", temp / "Projects", temp / "Downloads"
            data.mkdir()
            (data / "shelf.json").write_text(json.dumps({"projects": [], "root": str(shelf_root)}))
            (downloads / "brand").mkdir(parents=True)
            (downloads / "brand" / "logo.png").write_bytes(b"png")
            (downloads / "brief.pdf").write_bytes(b"pdf")
            (downloads / "site" / "node_modules" / "react").mkdir(parents=True)
            (downloads / "site" / "index.html").write_text("<h1>hi</h1>")
            (downloads / "site" / "node_modules" / "react" / "index.js").write_text("x")

            client = MCPClient(data)
            init = client.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-ai", "version": "1"}})["result"]
            self.assertEqual(init["protocolVersion"], "2025-06-18")
            self.assertEqual(init["serverInfo"]["name"], "devshelf")
            self.assertIn("tools", init["capabilities"])
            self.assertIn("list_projects", init["instructions"])
            self.assertIsNone(client.send("notifications/initialized", notify=True))
            self.assertEqual(client.send("ping")["result"], {})
            old = client.send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "codex-mcp-client"}})["result"]
            self.assertEqual(old["protocolVersion"], "2024-11-05")
            client.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-ai"}})

            tools = {tool["name"]: tool for tool in client.send("tools/list")["result"]["tools"]}
            self.assertGreaterEqual(len(tools), 19)
            for tool in tools.values():
                self.assertEqual(tool["inputSchema"]["type"], "object")
                self.assertTrue(tool["description"])
            self.assertTrue(tools["trash_items"]["annotations"]["destructiveHint"])
            self.assertTrue(tools["list_projects"]["annotations"]["readOnlyHint"])
            self.assertEqual(client.send("tools/call", {"name": "no_such_tool", "arguments": {}})["error"]["code"], -32602)
            self.assertEqual(client.send("resources/list")["error"]["code"], -32601)

            listed, _ = client.call("list_projects")
            self.assertEqual(listed["projects"], [])

            created, error = client.call("create_project", name="Portfolio Site", folders=["Code", "Design", "Images", "Documents"], color="purple", icon="globe", notes="Personal site")
            self.assertIsNone(error)
            project = created["created"]
            folder = pathlib.Path(project["path"]).resolve()
            self.assertEqual(folder, shelf_root / "Portfolio Site")
            self.assertEqual(sorted(project["folders"]), ["Code", "Design", "Documents", "Images"])
            self.assertTrue((folder / ".devshelf.json").exists())

            wp, error = client.call("create_project", name="Shop", template="WordPress")
            self.assertIsNone(error)
            self.assertTrue((shelf_root / "Shop" / "Code" / "theme").is_dir())
            _, error = client.call("create_project", name="X", template="Nope")
            self.assertIn("No template", error)

            made, _ = client.call("create_folders", project="portfolio", paths=["Design/Logos", "Documents/Contracts", "../escape"])
            self.assertEqual(made["created"], ["Design/Logos", "Documents/Contracts"])
            self.assertFalse((shelf_root / "escape").exists())

            added, error = client.call("add_files", project="Portfolio Site", sources=[str(downloads / "brand"), str(downloads / "brief.pdf")], destination="Design", mode="copy")
            self.assertIsNone(error)
            self.assertEqual(sorted(item["path"] for item in added["added"]), ["Design/brand", "Design/brief.pdf"])
            self.assertEqual({item["how"] for item in added["added"]}, {"copied"})
            self.assertTrue((downloads / "brief.pdf").exists(), "copy keeps the original")
            code, _ = client.call("add_files", project="Portfolio Site", sources=[str(downloads / "site")], destination="Code", mode="copy")
            self.assertTrue((folder / "Code/site/index.html").exists())
            self.assertFalse((folder / "Code/site/node_modules").exists(), "dependencies are skipped")
            linked_in, _ = client.call("add_files", project="Portfolio Site", sources=[str(downloads / "brief.pdf")], destination="Documents")
            self.assertEqual(linked_in["added"], [{"path": "Documents/brief.pdf", "how": "linked"}], "linking is the default")
            self.assertTrue((downloads / "brief.pdf").is_file(), "the original stays where it is")
            self.assertTrue((folder / "Documents/brief.pdf").is_symlink())

            # A linked folder: browsable and searchable, but its originals are protected.
            (downloads / "assets" / "icons").mkdir(parents=True)
            (downloads / "assets" / "icons" / "star.svg").write_text("<svg/>")
            linked, _ = client.call("add_files", project="Portfolio Site", sources=[str(downloads / "assets")], destination="Design")
            self.assertEqual(linked["added"], [{"path": "Design/assets", "how": "linked"}])
            self.assertTrue((downloads / "assets" / "icons" / "star.svg").exists(), "the selected folder was not moved")
            tree, _ = client.call("list_files", project="Portfolio Site", path="Design/assets", depth=3)
            self.assertIn("star.svg", tree)
            found, _ = client.call("find_files", query="star", project="Portfolio Site")
            self.assertEqual([f["path"] for f in found["files"]], ["Design/assets/icons/star.svg"])
            for tool, args in [("move_items", {"items": ["Design/assets/icons/star.svg"], "destination": "Images"}),
                               ("rename_item", {"path": "Design/assets/icons", "new_name": "x"}),
                               ("trash_items", {"paths": ["Design/assets/icons/star.svg"]})]:
                _, error = client.call(tool, project="Portfolio Site", **args)
                self.assertIn("original", error, tool)
            self.assertTrue((downloads / "assets" / "icons" / "star.svg").exists())
            removed_link, _ = client.call("trash_items", project="Portfolio Site", paths=["Design/assets", "Documents/brief.pdf"])
            self.assertEqual(sorted(removed_link["trashed"]), ["Design/assets", "Documents/brief.pdf"])
            self.assertTrue((downloads / "assets" / "icons" / "star.svg").exists(), "removing a link keeps the original")
            self.assertTrue((downloads / "brief.pdf").exists())
            self.assertFalse((folder / "Design/assets").is_symlink())
            moved_in, _ = client.call("add_files", project="Portfolio Site", sources=[str(downloads / "brief.pdf")], destination="Documents", mode="move")
            self.assertEqual(moved_in["added"], [{"path": "Documents/brief.pdf", "how": "moved"}], "moving only on request")
            self.assertFalse((downloads / "brief.pdf").exists())
            dupes, error = client.call("find_duplicates", project="Portfolio Site")
            self.assertIsNone(error)
            self.assertEqual(dupes["groups"], [], "the 3-byte copies are below the size limit")
            (downloads / "big.mov").write_bytes(bytes(range(256)) * 2000)
            (folder / "Documents" / "big copy.mov").write_bytes(bytes(range(256)) * 2000)
            client.call("add_files", project="Portfolio Site", sources=[str(downloads / "big.mov")], destination="Documents", mode="copy")
            dupes, _ = client.call("find_duplicates", project="Portfolio Site")
            self.assertEqual(len(dupes["groups"]), 1)
            self.assertEqual(dupes["groups"][0]["copies"], 2)
            self.assertTrue((downloads / "big.mov").exists(), "mode copy kept the original")
            self.assertTrue(dupes["groups"][0]["keep"].endswith("Documents/big.mov"))
            self.assertGreater(dupes["wasted_bytes"], 0)
            client.call("trash_items", project="Portfolio Site", paths=["Documents/big copy.mov", "Documents/big.mov"])
            _, error = client.call("add_files", project="Portfolio Site", sources=[str(temp / "missing.txt")])
            self.assertIn("doesn't exist", error)

            moved, error = client.call("move_items", project="Portfolio Site", items=["Design/brand/logo.png"], destination="Images/Logos")
            self.assertIsNone(error)
            self.assertEqual(moved["moved"], ["Images/Logos/logo.png"])
            _, error = client.call("move_items", project="Portfolio Site", items=["../../etc"], destination="Images")
            self.assertIn("outside the project", error)
            _, error = client.call("move_items", project="Portfolio Site", items=["."], destination="Images")
            self.assertIn("can't be moved", error)

            renamed, _ = client.call("rename_item", project="Portfolio Site", path="Design/brief.pdf", new_name="Project brief.pdf")
            self.assertEqual(renamed["renamed"], "Design/Project brief.pdf")
            _, error = client.call("rename_item", project="Portfolio Site", path="Design/Project brief.pdf", new_name="Logos")
            self.assertIn("already exists", error)

            found, _ = client.call("find_files", query="logo")
            self.assertEqual([f["path"] for f in found["files"]], ["Images/Logos/logo.png"])
            images, _ = client.call("find_files", kind="images", project="Portfolio Site")
            self.assertEqual(len(images["files"]), 1)
            tree, _ = client.call("list_files", project="Portfolio Site", depth=3)
            self.assertIn("Logos/", tree)
            self.assertIn("logo.png", tree)
            self.assertNotIn(".devshelf.json", tree)

            checklist, _ = client.call("update_checklist", project="Portfolio Site", add=["Export logos", "Write about page"])
            checklist, _ = client.call("update_checklist", project="Portfolio Site", complete=["export LOGOS"], remove=["nothing"])
            self.assertEqual([t["done"] for t in checklist["checklist"]], [True, False])
            self.assertEqual(checklist["not_found"], ["nothing"])

            marked, error = client.call("mark_folder", project="Portfolio Site", path="Images/Logos", pinned=True, favorite=True, color="pink")
            self.assertIsNone(error)
            self.assertEqual(marked, {"folder": "Images/Logos", "pinned": True, "favorite": True, "color": "pink"})
            _, error = client.call("mark_folder", project="Portfolio Site", path="Images/Logos/logo.png", pinned=True)
            self.assertIn("isn't a folder", error)
            _, error = client.call("mark_folder", project="Portfolio Site", path=".", pinned=True)
            self.assertIn("isn't a folder", error)
            _, error = client.call("mark_folder", project="Portfolio Site", path="Images", color="beige")
            self.assertIn("Colours", error)
            client.call("rename_item", project="Portfolio Site", path="Images/Logos", new_name="Brand marks")
            client.call("move_items", project="Portfolio Site", items=["Images/Brand marks"], destination="Design")
            details, _ = client.call("get_project", project="Portfolio Site", include_git=False)
            self.assertEqual([(m["folder"], m["pinned"], m["color"]) for m in details["folder_marks"]], [("Design/Brand marks", True, "pink")])
            client.call("move_items", project="Portfolio Site", items=["Design/Brand marks"], destination="Images")
            client.call("rename_item", project="Portfolio Site", path="Images/Brand marks", new_name="Logos")
            unmarked, _ = client.call("mark_folder", project="Portfolio Site", path="Images/Logos", pinned=False, favorite=False, color="none")
            self.assertEqual(unmarked["color"], "project colour")
            client.call("mark_folder", project="Portfolio Site", path="Design", pinned=True)

            updated, error = client.call("update_project", project="Portfolio Site", name="Portfolio 2026", status="waiting", color="teal")
            self.assertIsNone(error)
            self.assertEqual(pathlib.Path(updated["updated"]["path"]).name, "Portfolio 2026")
            self.assertTrue((shelf_root / "Portfolio 2026" / "Images/Logos/logo.png").exists())
            folder = shelf_root / "Portfolio 2026"
            _, error = client.call("update_project", project="Portfolio 2026", status="later")
            self.assertIn("Status must be", error)

            details, _ = client.call("get_project", project="Portfolio 2026")
            self.assertEqual(details["status"], "waiting")
            self.assertEqual(details["color"], "teal")
            self.assertEqual(len(details["checklist"]), 2)
            self.assertIn("Images", [group["type"] for group in details["file_types"]])
            self.assertEqual(details["git"], [])

            _, error = client.call("trash_items", project="Portfolio 2026", paths=["."])
            self.assertIn("can't be trashed", error)
            _, error = client.call("get_project", project="Nope")
            self.assertIn("No project", error)
            _, error = client.call("transfer_to_drive", project="Portfolio 2026", drive="Imaginary Drive")
            self.assertIn("No connected drive", error)

            outside = temp / "Old work"
            (outside / "Design").mkdir(parents=True)
            existing, _ = client.call("add_existing_folder", path=str(outside), color="red")
            self.assertEqual(existing["added"]["name"], "Old work")
            again, _ = client.call("add_existing_folder", path=str(outside))
            self.assertIn("already_on_shelf", again)

            archive_dir = temp / "zips"
            archive_dir.mkdir()
            (folder / "Code/site/.env").write_text("SECRET=1")
            zipped, error = client.call("zip_folder", project="Portfolio 2026", path="Code", output=str(archive_dir))
            self.assertIsNone(error)
            names = zipfile.ZipFile(zipped["zip"]).namelist()
            self.assertIn("Code/site/index.html", names)
            self.assertFalse(any(".env" in name for name in names))

            templates, _ = client.call("list_templates")
            self.assertIn("Images", templates["folder_types"])
            self.assertTrue(any(t["id"] == "wordpress" for t in templates["templates"]))
            drives, error = client.call("list_drives")
            self.assertIsNone(error)
            scanned, error = client.call("list_scanned_projects", query="anything")
            self.assertIsNone(error)

            removed, _ = client.call("remove_from_shelf", project="Old work")
            self.assertTrue(outside.exists(), "removing keeps the folder")
            listed, _ = client.call("list_projects")
            self.assertEqual(sorted(p["name"] for p in listed["projects"]), ["Portfolio 2026", "Shop"])
            client.close()

            shelf = json.loads((data / "shelf.json").read_text())
            self.assertEqual(len(shelf["projects"]), 2)
            log = json.loads((data / "mcp-log.json").read_text())
            self.assertTrue(all(entry["client"] == "Claude" for entry in log))
            self.assertTrue(any("Created project “Portfolio Site”" in entry["summary"] for entry in log))
            metadata = json.loads((folder / ".devshelf.json").read_text())
            self.assertEqual(metadata["status"], "waiting")
            self.assertEqual(len(metadata["tasks"]), 2)
            self.assertEqual(metadata["folderMarks"], {"Design": {"pinned": True, "favorite": False}})

    def test_bad_input_does_not_crash(self):
        with tempfile.TemporaryDirectory(prefix="devshelf-mcp-") as temp:
            client = MCPClient(pathlib.Path(temp))
            client.process.stdin.write("this is not json\n")
            client.process.stdin.flush()
            self.assertEqual(json.loads(client.process.stdout.readline())["error"]["code"], -32700)
            self.assertEqual(client.send("tools/call", {"name": "list_projects"})["result"]["isError"], False)
            client.close()
            self.assertEqual(client.process.returncode, 0)


if __name__ == "__main__":
    unittest.main()
