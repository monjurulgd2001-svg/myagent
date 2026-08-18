# Hermes Repo Pusher (GUI)

`push_gui.py` — একটা ডেস্কটপ GUI যা এই folder-এর সব ফাইল **GitHub API call** দিয়ে
এক ক্লিকে রিপো-তে push করে। `git` install করা লাগে না — শুধু Python।

## চালানো

```bash
python3 push_gui.py       # macOS / Linux
py push_gui.py            # Windows (অথবা file-এ double-click)
```

> tkinter সাধারণত Python-এর সাথেই আসে। Linux-এ না থাকলে:
> `sudo apt install python3-tk` (Debian/Ubuntu) অথবা `sudo dnf install python3-tkinter`।

## GitHub Token কোথায়

1. GitHub → Settings → Developer settings → **Personal access tokens**
2. **Fine-grained token** (রিকমেন্ডেড): শুধু এই repo-তে access দিন,
   permission: **Contents → Read and write**।
   - repo এখনো না থাকলে (‘create’ টিক দিতে চাইলে) classic token-এ
     `repo` scope দিন, অথবা আগে repo বানিয়ে নিন।
3. Token-টা app-এ “GitHub Token” ঘরে paste করুন। (এটা **কখনো save হয় না**
   — অন্য সব সেটিংস `push_gui_config.json`-এ সেভ হয়, token বাদে।)

## স্টেপ

1. **GitHub Token** দিন
2. **Owner** = আপনার GitHub username বা org (যেমন `your-username`)
3. **Repository** = repo-এর নাম (যেমন `hermes-agent`)
4. **Branch** = যে branch-এ যাবে (default `main`)
5. **Local folder** = এই folder (default দেওয়াই আছে)
6. **Test connection** দিয়ে যাচাই করুন
7. **🚀 Push to repo** — এক commit-এ সব ফাইল যাবে

## কীভাবে push করে (নিরাপদ)

Git Data API ব্যবহার করে: **blobs → tree → commit → ref update**। ফলে সব ফাইল
**একটাই clean commit**-এ যায় (per-file আলাদা commit নয়)। বিদ্যমান branch থাকলে
তার উপর commit হয়; না থাকলে default থেকে branch বানায়।

## যা push হয় না (auto-skip)

`.git/`, `__pycache__/`, `node_modules/`, `.venv/`, `.pyc`, `push_gui_config.json`।

## Note

- `.sh` ফাইল আর executable ফাইল `100755` (executable bit) সহ push হয়।
- এই pusher নিজেও (`push_gui.py`) repo-তে যাবে — সমস্যা নেই। না চাইলে
  push-এর আগে ফাইলটা folder-এর বাইরে সরিয়ে নিন।
