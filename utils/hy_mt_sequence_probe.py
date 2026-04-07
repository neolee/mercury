#!/usr/bin/env python3

import argparse
import concurrent.futures
import json
import sys
import textwrap
import urllib.error
import urllib.request
from pathlib import Path


BUILTIN_PROMPTS = {
    "mercury-minimal": {
        "system": "",
        "user": textwrap.dedent(
            """
            Translate the following text into {target_language}. Output the translation only.

            {source_text}
            """
        ).strip(),
    },
    "mercury-builtin": {
        "system": textwrap.dedent(
            """
            You are a professional translator.
            Translate the given text faithfully into {target_language}.
            Output the translation only - no explanation, no preamble, no formatting marks.
            """
        ).strip(),
        "user": textwrap.dedent(
            """
            Translate the following text into {target_language}. Output the translation only.

            {previous_text_block_mercury}{source_text}
            """
        ).strip(),
    },
    "hy-official-en": {
        "system": "",
        "user": textwrap.dedent(
            """
            Translate the following segment into {target_language}, without additional explanation.

            {source_text}
            """
        ).strip(),
    },
    "hy-official-zh": {
        "system": "",
        "user": textwrap.dedent(
            """
            将以下文本翻译为{target_language}，注意只需要输出翻译后的结果，不要额外解释：

            {source_text}
            """
        ).strip(),
    },
    "hy-context-en": {
        "system": "",
        "user": textwrap.dedent(
            """
            {previous_text_block_official}Translate the following segment into {target_language}, without additional explanation.

            {source_text}
            """
        ).strip(),
    },
    "hy-context-zh": {
        "system": "",
        "user": textwrap.dedent(
            """
            {previous_text_block_zh}参考上面的信息，把下面的文本翻译成{target_language}，注意不需要翻译上文，也不要额外解释：
            {source_text}
            """
        ).strip(),
    },
    "hy-context-en-literal": {
        "system": "",
        "user": textwrap.dedent(
            """
            {previous_text_block_en_literal}Refer to the information above and translate the text below into {target_language}. Do not translate the above text, and do not provide any additional explanation:
            {source_text}
            """
        ).strip(),
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a sequence of independent chat-completions requests to a llama.cpp-compatible server."
    )
    parser.add_argument(
        "segments_file",
        help="Text file containing consecutive source segments separated by a line with only ---",
    )
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8080",
        help="Server base URL. Accepts either http://host:port or http://host:port/v1",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Optional model name to send in the OpenAI-compatible request body",
    )
    parser.add_argument(
        "--target-language",
        default="Chinese",
        help="Target language label inserted into the prompt",
    )
    parser.add_argument(
        "--prompt-style",
        choices=sorted(BUILTIN_PROMPTS.keys()),
        default="mercury-minimal",
        help="Built-in prompt style to use when --prompt-template-file is not provided",
    )
    parser.add_argument(
        "--prompt-template-file",
        default=None,
        help="Optional template file using {target_language}, {source_text}, {previous_text}, {previous_text_block}",
    )
    parser.add_argument(
        "--system-template-file",
        default=None,
        help="Optional system template file using {target_language}, {source_text}, {previous_text}",
    )
    parser.add_argument(
        "--output-json",
        default=None,
        help="Optional path to save structured results as JSON",
    )
    parser.add_argument(
        "--print-prompt",
        action="store_true",
        help="Print the exact prompt for each segment",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=1,
        help="Number of requests to run concurrently. Use 1 to match strictly serial execution.",
    )
    return parser.parse_args()


def load_segments(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    normalized = raw.replace("\r\n", "\n").replace("\r", "\n")
    chunks = []
    current = []
    for line in normalized.split("\n"):
        if line.strip() == "---":
            chunk = "\n".join(current).strip()
            if chunk:
                chunks.append(chunk)
            current = []
            continue
        current.append(line)

    tail = "\n".join(current).strip()
    if tail:
        chunks.append(tail)
    return chunks


def resolve_endpoint(base_url: str) -> str:
    trimmed = base_url.rstrip("/")
    if trimmed.endswith("/v1"):
        return trimmed + "/chat/completions"
    return trimmed + "/v1/chat/completions"


def load_prompt_templates(args: argparse.Namespace) -> tuple[str, str]:
    system_template = ""
    if args.system_template_file:
        system_template = Path(args.system_template_file).read_text(encoding="utf-8").strip()

    if args.prompt_template_file:
        user_template = Path(args.prompt_template_file).read_text(encoding="utf-8").strip()
        return system_template, user_template

    builtin = BUILTIN_PROMPTS[args.prompt_style]
    return builtin["system"], builtin["user"]


def build_prompt(template: str, target_language: str, source_text: str, previous_text: str | None) -> str:
    previous = previous_text or ""
    previous_text_block_official = ""
    previous_text_block_mercury = ""
    previous_text_block_zh = ""
    previous_text_block_en_literal = ""
    if previous:
        previous_text_block_official = f"Context (do not translate):\n{previous}\n\n"
        previous_text_block_mercury = f"Context (preceding paragraph, do not translate):\n{previous}\n\n"
        previous_text_block_zh = f"{previous}\n"
        previous_text_block_en_literal = f"{previous}\n"
    return template.format(
        target_language=target_language,
        source_text=source_text,
        previous_text=previous,
        previous_text_block_official=previous_text_block_official,
        previous_text_block_mercury=previous_text_block_mercury,
        previous_text_block_zh=previous_text_block_zh,
        previous_text_block_en_literal=previous_text_block_en_literal,
    ).strip()


def send_chat_request(endpoint: str, model: str | None, system_prompt: str, user_prompt: str) -> dict:
    messages = []
    if system_prompt.strip():
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": user_prompt})

    payload = {"messages": messages, "stream": False}
    if model:
        payload["model"] = model

    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read().decode("utf-8"))


def extract_text(response: dict) -> str:
    choices = response.get("choices") or []
    if not choices:
        return ""
    first = choices[0]
    message = first.get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts).strip()
    return ""


def execute_request(index: int, endpoint: str, model: str | None, system_prompt: str, user_prompt: str) -> dict:
    try:
        response = send_chat_request(
            endpoint=endpoint,
            model=model,
            system_prompt=system_prompt,
            user_prompt=user_prompt,
        )
        output = extract_text(response)
        usage = response.get("usage") or {}
        return {
            "index": index,
            "output": output,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "error": None,
        }
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        return {
            "index": index,
            "output": "",
            "prompt_tokens": None,
            "completion_tokens": None,
            "error": f"HTTP {error.code} {error.reason}\n{body}",
        }
    except Exception as error:  # noqa: BLE001
        return {
            "index": index,
            "output": "",
            "prompt_tokens": None,
            "completion_tokens": None,
            "error": str(error),
        }


def main() -> int:
    args = parse_args()
    segments_path = Path(args.segments_file)
    if not segments_path.exists():
        print(f"Segments file not found: {segments_path}", file=sys.stderr)
        return 1

    segments = load_segments(segments_path)
    if not segments:
        print("No segments found. Separate consecutive segments with a line containing only ---", file=sys.stderr)
        return 1

    system_template, user_template = load_prompt_templates(args)
    endpoint = resolve_endpoint(args.base_url)
    concurrency = max(1, args.concurrency)
    prepared_requests = []

    for index, segment in enumerate(segments, start=1):
        previous_text = segments[index - 2] if index > 1 else None
        system_prompt = build_prompt(
            template=system_template,
            target_language=args.target_language,
            source_text=segment,
            previous_text=previous_text,
        ) if system_template else ""
        user_prompt = build_prompt(
            template=user_template,
            target_language=args.target_language,
            source_text=segment,
            previous_text=previous_text,
        )

        prepared_requests.append(
            {
                "index": index,
                "source_text": segment,
                "previous_text": previous_text,
                "system_prompt": system_prompt,
                "user_prompt": user_prompt,
            }
        )

    results_by_index: dict[int, dict] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        future_map = {
            executor.submit(
                execute_request,
                item["index"],
                endpoint,
                args.model,
                item["system_prompt"],
                item["user_prompt"],
            ): item["index"]
            for item in prepared_requests
        }
        for future in concurrent.futures.as_completed(future_map):
            result = future.result()
            results_by_index[result["index"]] = result

    results = []
    for item in prepared_requests:
        index = item["index"]
        segment = item["source_text"]
        system_prompt = item["system_prompt"]
        user_prompt = item["user_prompt"]
        result = results_by_index[index]
        print(f"===== Segment {index} =====")
        print("Source:")
        print(segment)
        if args.print_prompt:
            if system_prompt:
                print("\nSystem Prompt:")
                print(system_prompt)
            print("\nUser Prompt:")
            print(user_prompt)

        if result["error"] is None:
            output = result["output"]
            print("\nOutput:")
            print(output or "<empty>")
        else:
            output = ""
            print("\nError:")
            print(result["error"])

        print()
        results.append(
            {
                "index": index,
                "source_text": segment,
                "previous_text": item["previous_text"],
                "system_prompt": system_prompt,
                "user_prompt": user_prompt,
                "output": output,
                "prompt_tokens": result["prompt_tokens"],
                "completion_tokens": result["completion_tokens"],
                "error": result["error"],
            }
        )

    if args.output_json:
        output_path = Path(args.output_json)
        output_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Saved JSON results to {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())