#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Hermes Repo Pusher — GUI
========================
একটা সিমপল GUI — একটা folder-এর সব ফাইল GitHub API দিয়ে একটা commit-এ
রিপো-তে push করে। কোনো `git` install লাগে না, শুধু Python (stdlib)।

Run:  python3 push_gui.py   (Windows: py push_gui.py অথবা double-click)
"""
import base64
import json
import os
import queue
import threading
import urllib.error
import urllib.request

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

API = "https://api.github.com"
CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "push_gui_config.json")

# এই folder/file গুলো push হবে না
SKIP_DIRS = {".git", "__pycache__", "node_modules", ".venv", ".idea", ".vscode"}
SKIP_FILES = {"push_gui_config.json", ".DS_Store"}


# ---------------------------------------------------------------- GitHub API
class GitHub:
    def __init__(self, token):
        self.token = token.strip()

    def _req(self, method, path, body=None):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "hermes-repo-pusher")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                detail = json.loads(detail).get("message", detail)
            except Exception:
                pass
            raise RuntimeError("HTTP %s %s → %s" % (e.code, e.reason, detail))
        except urllib.error.URLError as e:
            raise RuntimeError("Network error: %s" % e.reason)

    def whoami(self):
        return self._req("GET", "/user")

    def get_repo(self, owner, repo):
        return self._req("GET", "/repos/%s/%s" % (owner, repo))

    def create_repo(self, owner, repo, private=True):
        me = self.whoami()
        if me.get("login", "").lower() == owner.lower():
            return self._req("POST", "/user/repos",
                             {"name": repo, "private": private, "auto_init": True})
        return self._req("POST", "/orgs/%s/repos" % owner,
                         {"name": repo, "private": private, "auto_init": True})

    def get_ref(self, owner, repo, branch):
        return self._req("GET", "/repos/%s/%s/git/ref/heads/%s" % (owner, repo, branch))

    def get_commit(self, owner, repo, sha):
        return self._req("GET", "/repos/%s/%s/git/commits/%s" % (owner, repo, sha))

    def create_branch(self, owner, repo, new_branch, from_sha):
        return self._req("POST", "/repos/%s/%s/git/refs" % (owner, repo),
                         {"ref": "refs/heads/" + new_branch, "sha": from_sha})

    def create_blob(self, owner, repo, content_b64):
        return self._req("POST", "/repos/%s/%s/git/blobs" % (owner, repo),
                         {"content": content_b64, "encoding": "base64"})

    def create_tree(self, owner, repo, base_tree, tree):
        body = {"tree": tree}
        if base_tree:
            body["base_tree"] = base_tree
        return self._req("POST", "/repos/%s/%s/git/trees" % (owner, repo), body)

    def create_commit(self, owner, repo, message, tree_sha, parents):
        return self._req("POST", "/repos/%s/%s/git/commits" % (owner, repo),
                         {"message": message, "tree": tree_sha, "parents": parents})

    def update_ref(self, owner, repo, branch, sha, force=True):
        return self._req("PATCH", "/repos/%s/%s/git/refs/heads/%s" % (owner, repo, branch),
                         {"sha": sha, "force": force})


# ---------------------------------------------------------------- helpers
def collect_files(root):
    """root-এর সব ফাইল (relative posix path, abs path) list করে, skip নিয়ম মেনে।"""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn in SKIP_FILES or fn.endswith(".pyc"):
                continue
            ap = os.path.join(dirpath, fn)
            rel = os.path.relpath(ap, root).replace(os.sep, "/")
            out.append((rel, ap))
    return sorted(out)


# ---------------------------------------------------------------- GUI
class App:
    def __init__(self, master):
        self.m = master
        master.title("Hermes Repo Pusher")
        master.geometry("720x640")
        master.minsize(640, 560)

        self.q = queue.Queue()
        self.busy = False

        frm = ttk.Frame(master)
        frm.pack(fill="x", padx=10, pady=6)

        self.vars = {}

        def row(label, key, show=None, default=""):
            r = ttk.Frame(frm)
            r.pack(fill="x", pady=3)
            ttk.Label(r, text=label, width=16, anchor="w").pack(side="left")
            v = tk.StringVar(value=default)
            e = ttk.Entry(r, textvariable=v, show=show)
            e.pack(side="left", fill="x", expand=True)
            self.vars[key] = v
            return r, e

        _, self.tok_entry = row("GitHub Token", "token", show="*")
        ttk.Button(self.tok_entry.master, text="eye", width=4,
                   command=self.toggle_token).pack(side="left", padx=(4, 0))

        row("Owner (user/org)", "owner")
        row("Repository", "repo")
        row("Branch", "branch", default="main")
        row("Commit message", "message",
            default="Restructure: split inbuilt features into files")

        fr = ttk.Frame(frm)
        fr.pack(fill="x", pady=3)
        ttk.Label(fr, text="Local folder", width=16, anchor="w").pack(side="left")
        self.vars["folder"] = tk.StringVar(
            value=os.path.dirname(os.path.abspath(__file__)))
        ttk.Entry(fr, textvariable=self.vars["folder"]).pack(
            side="left", fill="x", expand=True)
        ttk.Button(fr, text="Browse…", command=self.browse).pack(
            side="left", padx=(4, 0))

        opt = ttk.Frame(frm)
        opt.pack(fill="x", pady=6)
        self.create_var = tk.BooleanVar(value=True)
        self.private_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(opt, text="repo না থাকলে create",
                        variable=self.create_var).pack(side="left", padx=(0, 16))
        ttk.Checkbutton(opt, text="private repo",
                        variable=self.private_var).pack(side="left")

        btns = ttk.Frame(master)
        btns.pack(fill="x", padx=10, pady=6)
        self.test_btn = ttk.Button(btns, text="Test connection",
                                   command=self.on_test)
        self.test_btn.pack(side="left")
        self.push_btn = ttk.Button(btns, text="Push to repo",
                                   command=self.on_push)
        self.push_btn.pack(side="left", padx=8)
        ttk.Button(btns, text="Save settings",
                   command=self.save_config).pack(side="right")

        self.pb = ttk.Progressbar(master, mode="determinate")
        self.pb.pack(fill="x", padx=10, pady=(2, 4))

        ttk.Label(master, text="Log").pack(anchor="w", padx=10)
        self.log = tk.Text(master, height=16, wrap="word",
                           bg="#0f1117", fg="#cfe3ff",
                           insertbackground="#cfe3ff")
        self.log.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.log.configure(state="disabled")

        self.load_config()
        self.m.after(100, self.drain)

    # -------- ui helpers
    def toggle_token(self):
        self.tok_entry.configure(show="" if self.tok_entry.cget("show") else "*")

    def browse(self):
        d = filedialog.askdirectory(initialdir=self.vars["folder"].get() or ".")
        if d:
            self.vars["folder"].set(d)

    def emit(self, msg):
        self.q.put(("log", msg))

    def set_progress(self, done, total):
        self.q.put(("pb", (done, total)))

    def drain(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "log":
                    self.log.configure(state="normal")
                    self.log.insert("end", payload + "\n")
                    self.log.see("end")
                    self.log.configure(state="disabled")
                elif kind == "pb":
                    done, total = payload
                    self.pb.configure(maximum=max(total, 1), value=done)
                elif kind == "done":
                    self.busy = False
                    self.push_btn.configure(state="normal")
                    self.test_btn.configure(state="normal")
                    if payload:
                        messagebox.showinfo("Done", payload)
                elif kind == "error":
                    self.busy = False
                    self.push_btn.configure(state="normal")
                    self.test_btn.configure(state="normal")
                    messagebox.showerror("Error", payload)
        except queue.Empty:
            pass
        self.m.after(100, self.drain)

    def cfg(self):
        return {k: v.get().strip() for k, v in self.vars.items()}

    def validate(self, need_folder=True):
        c = self.cfg()
        if not c["token"]:
            raise ValueError("GitHub Token দিন")
        if not c["owner"] or not c["repo"]:
            raise ValueError("Owner আর Repository দিন")
        if not c["branch"]:
            raise ValueError("Branch দিন")
        if need_folder and not os.path.isdir(c["folder"]):
            raise ValueError("Local folder পাওয়া যায়নি")
        return c

    # -------- config persistence (token বাদে)
    def save_config(self):
        c = self.cfg()
        c.pop("token", None)
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(c, f, indent=2)
            self.emit("settings saved (token সেভ হয় না)")
        except Exception as e:
            self.emit("settings save failed: %s" % e)

    def load_config(self):
        if not os.path.exists(CONFIG_FILE):
            return
        try:
            with open(CONFIG_FILE) as f:
                c = json.load(f)
            for k, v in c.items():
                if k in self.vars and v:
                    self.vars[k].set(v)
        except Exception:
            pass

    # -------- actions
    def on_test(self):
        if self.busy:
            return
        try:
            c = self.validate(need_folder=False)
        except ValueError as e:
            messagebox.showwarning("Missing", str(e))
            return
        self.busy = True
        self.test_btn.configure(state="disabled")
        self.push_btn.configure(state="disabled")
        threading.Thread(target=self._test_worker, args=(c,), daemon=True).start()

    def _test_worker(self, c):
        try:
            gh = GitHub(c["token"])
            me = gh.whoami()
            self.emit("token OK — logged in as %s" % me.get("login"))
            try:
                r = gh.get_repo(c["owner"], c["repo"])
                self.emit("repo found: %s (default branch: %s, private: %s)"
                          % (r["full_name"], r["default_branch"], r["private"]))
            except RuntimeError as e:
                self.emit("repo পাওয়া যায়নি: %s" % e)
                self.emit("(Push-এ 'repo না থাকলে create' টিক দিলে বানাবে)")
            self.q.put(("done", None))
        except Exception as e:
            self.emit("ERROR: %s" % e)
            self.q.put(("error", str(e)))

    def on_push(self):
        if self.busy:
            return
        try:
            c = self.validate()
        except ValueError as e:
            messagebox.showwarning("Missing", str(e))
            return
        files = collect_files(c["folder"])
        if not files:
            messagebox.showwarning("Empty", "folder-এ push করার মতো ফাইল নেই")
            return
        if not messagebox.askyesno(
                "Confirm",
                "%d টি ফাইল %s/%s (branch: %s)-এ push হবে। এগোবে?"
                % (len(files), c["owner"], c["repo"], c["branch"])):
            return
        self.busy = True
        self.push_btn.configure(state="disabled")
        self.test_btn.configure(state="disabled")
        self.pb.configure(value=0)
        threading.Thread(target=self._push_worker, args=(c, files),
                         daemon=True).start()

    def _push_worker(self, c, files):
        try:
            gh = GitHub(c["token"])
            owner, repo, branch = c["owner"], c["repo"], c["branch"]

            # 1) repo আছে কিনা
            try:
                r = gh.get_repo(owner, repo)
                default_branch = r["default_branch"]
                self.emit("repo: %s" % r["full_name"])
            except RuntimeError:
                if not self.create_var.get():
                    raise RuntimeError("repo নেই আর create অপশন অफ — push বন্ধ")
                self.emit("repo নেই, তৈরি করছি…")
                r = gh.create_repo(owner, repo, private=self.private_var.get())
                default_branch = r.get("default_branch", "main")
                self.emit("repo created: %s" % r["full_name"])

            # 2) parent commit sha
            parents = []
            base_tree = None
            try:
                ref = gh.get_ref(owner, repo, branch)
                head_sha = ref["object"]["sha"]
                parents = [head_sha]
                commit = gh.get_commit(owner, repo, head_sha)
                base_tree = commit["tree"]["sha"]
                self.emit("branch '%s' আছে (এর উপর commit হবে)" % branch)
            except RuntimeError:
                self.emit("branch '%s' নেই, default '%s' থেকে তৈরি করছি"
                          % (branch, default_branch))
                try:
                    base_ref = gh.get_ref(owner, repo, default_branch)
                    base_sha = base_ref["object"]["sha"]
                    gh.create_branch(owner, repo, branch, base_sha)
                    parents = [base_sha]
                    commit = gh.get_commit(owner, repo, base_sha)
                    base_tree = commit["tree"]["sha"]
                    self.emit("branch '%s' তৈরি" % branch)
                except RuntimeError as e:
                    self.emit("default branch নেই — প্রথম commit হিসেবে যাবে (%s)" % e)
                    parents = []
                    base_tree = None

            # 3) blobs
            total = len(files)
            tree = []
            for i, (rel, ap) in enumerate(files, 1):
                with open(ap, "rb") as f:
                    data = f.read()
                b64 = base64.b64encode(data).decode()
                blob = gh.create_blob(owner, repo, b64)
                mode = "100755" if (ap.endswith(".sh") or self._is_exec(ap)) else "100644"
                tree.append({"path": rel, "mode": mode, "type": "blob",
                             "sha": blob["sha"]})
                self.emit("  + %s" % rel)
                self.set_progress(i, total + 3)

            # 4) tree
            self.emit("tree বানানো হচ্ছে…")
            new_tree = gh.create_tree(owner, repo, base_tree, tree)
            self.set_progress(total + 1, total + 3)

            # 5) commit
            self.emit("commit তৈরি…")
            commit = gh.create_commit(owner, repo, c["message"] or "update",
                                      new_tree["sha"], parents)
            self.set_progress(total + 2, total + 3)

            # 6) ref update / create
            self.emit("branch update…")
            try:
                gh.update_ref(owner, repo, branch, commit["sha"], force=True)
            except RuntimeError:
                gh.create_branch(owner, repo, branch, commit["sha"])
            self.set_progress(total + 3, total + 3)

            url = "https://github.com/%s/%s/tree/%s" % (owner, repo, branch)
            self.emit("DONE! %d টি ফাইল push হয়েছে।" % total)
            self.emit("   %s" % url)
            self.q.put(("done", "Push সফল! %d ফাইল → %s" % (total, url)))
        except Exception as e:
            self.emit("push failed: %s" % e)
            self.q.put(("error", str(e)))

    @staticmethod
    def _is_exec(path):
        try:
            return os.access(path, os.X_OK) and not os.path.isdir(path)
        except Exception:
            return False


def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
