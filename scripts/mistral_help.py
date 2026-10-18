#!/usr/bin/env python3
"""Ask the Scaleway Mistral helper without changing Codex's primary model."""

import argparse
import socket
import json
import os
import sys
import urllib.error
import urllib.request

BASE_URL = "https://44d7f3b3-b8d5-4091-8f7d-058dc221e241.ifr.fr-par.scaleway.com/v1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", nargs="?", help="Question, or read it from stdin")
    parser.add_argument("--model", default=os.getenv(
        "SCW_MISTRAL_MODEL", "mistral/mistral-small-3.2-24b-instruct-2506:fp8"
    ))
    parser.add_argument("--models", action="store_true", help="List deployed models")
    parser.add_argument("--max-tokens", type=int, default=1024)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    key = os.getenv("SCW_SECRET_KEY") or os.getenv("SCALEWAY_API_KEY")
    if not key:
        parser.error("Set SCW_SECRET_KEY or SCALEWAY_API_KEY in your environment")

    def request(path, payload=None):
        req = urllib.request.Request(
            BASE_URL + path,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=args.timeout) as response:
            return json.load(response)

    try:
        if args.models or not args.model:
            models = request("/models")
            if args.models:
                print(json.dumps(models, indent=2))
                return
            ids = [item["id"] for item in models.get("data", [])]
            if len(ids) != 1:
                parser.error("Choose --model from: " + ", ".join(ids))
            args.model = ids[0]
        prompt = args.prompt if args.prompt is not None else sys.stdin.read()
        if not prompt.strip():
            parser.error("Provide a question or pipe text on stdin")
        response = request("/chat/completions", {
            "model": args.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": args.max_tokens,
            "stream": False,
        })
        print(response["choices"][0]["message"]["content"])
    except urllib.error.HTTPError as error:
        print("Scaleway returned HTTP " + str(error.code), file=sys.stderr)
        sys.exit(1)
    except (urllib.error.URLError, TimeoutError, socket.timeout, KeyError, ValueError) as error:
        print("Mistral request failed: " + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
