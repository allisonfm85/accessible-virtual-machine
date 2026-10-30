#!/usr/bin/env python3
"""Asks a model served by the Llama app on this Mac (OpenAI-style API on
port 9931) to review one file or diff, and prints its answer with timings.

    Tools/local-review.py MODEL PATH [words that focus the review]

MODEL is a name from the app, e.g. "ggml-org/Qwen3.8-27B-GGUF:Q8_0". The
presets give each model a 4096-token context; a whole file needs more, so
give the entry in ~/.config/llama/models.user.ini a larger ctx-size."""
import json, sys, time, urllib.request
model, path = sys.argv[1], sys.argv[2]
focus = " ".join(sys.argv[3:])
code = open(path, errors="replace").read()
brief = (
 "You are reviewing part of AVM, a macOS app for blind users that runs Windows and Linux in QEMU. "
 "Report ONLY real bugs you can trigger: for each, give the line, the exact input or sequence that triggers it, "
 "and what goes wrong. Then a separate short list of things you suspected but could not confirm. "
 "No style notes, no praise, no summaries of what the code does. " + focus)
req = {"model": model, "temperature": 0.2, "max_tokens": 2500,
       "chat_template_kwargs": {"enable_thinking": False},   # Qwen3 spends the whole budget thinking otherwise
       "messages": [{"role": "system", "content": brief},
                    {"role": "user", "content": f"File: {path}\n\n```\n{code}\n```"}]}
t = time.time()
r = urllib.request.Request("http://127.0.0.1:9931/v1/chat/completions", data=json.dumps(req).encode(),
                           headers={"Content-Type": "application/json"})
with urllib.request.urlopen(r, timeout=900) as resp:
    d = json.load(resp)
m = d["choices"][0]["message"]
print(m.get("content") or "(no answer; reasoning only: %d chars)" % len(m.get("reasoning_content") or ""))
u = d.get("usage", {}); tm = d.get("timings", {})
print(f"\n--- {time.time()-t:.0f} s; prompt {u.get('prompt_tokens')} tokens, answer {u.get('completion_tokens')} tokens; "
      f"{tm.get('predicted_per_second', 0):.1f} tokens/s")
