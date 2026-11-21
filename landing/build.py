#!/usr/bin/env python3
"""Render the Pakperk product page in English and Chinese from one source.

Two languages that must say the same thing are too easy to let drift, so the
copy lives here as data and the markup exists once. Run it from the repo root:

    python3 landing/build.py

It writes landing/index.html (English) and landing/zh/index.html (Chinese).
Nothing else in landing/ is generated; styles.css, app.js and assets/ are
hand-maintained.
"""

from __future__ import annotations

import html
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

# The build that download/ serves. Keep in step with the file actually
# installed on the server (see README.md).
APK = {
    "file": "pakperk-0.2.0-dev.apk",
    "version": "0.2.0-dev",
    "build": "2",
    "bytes": 29_959_804,
    "size": "28.6 MB",
    "sha256": "155d34e9a1748f56494d9a8c6749f22cd5e78b6e0e9f92c08e013519d048e08b",
    "cert": "fcf345e1a6d4e5d9579f4125ec48d88dc8b7041b20a908ca1f31df358a3d8cd3",
    "package": "app.pakperk.pakperk.dev",
}

ICONS = {
    "library": '<path d="M6 3.5h12a1 1 0 0 1 1 1v16l-7-4-7 4v-16a1 1 0 0 1 1-1Z"/>',
    "cloud": '<path d="M7.5 18.5A4.5 4.5 0 0 1 7 9.6a5.5 5.5 0 0 1 10.6 1.5 3.7 3.7 0 0 1-.6 7.4Z"/>',
    "lock": '<rect x="4.5" y="10.5" width="15" height="9.5" rx="2"/><path d="M8 10.5V7.8a4 4 0 0 1 8 0v2.7"/>',
    "external": '<path d="M10 14 20 4M20 4h-5M20 4v5"/><path d="M19 13.5V19a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 19V8a1.5 1.5 0 0 1 1.5-1.5H12"/>',
    "shield": '<path d="M12 3.5 5 6.4v5.2c0 4.2 2.8 7.5 7 8.9 4.2-1.4 7-4.7 7-8.9V6.4Z"/><path d="m9.3 12 1.9 1.9 3.6-3.8"/>',
    "access": '<circle cx="12" cy="12" r="8.5"/><path d="M12 8.2v7.6M8.2 12h7.6"/>',
    "lines": '<path d="M4 7.5h16M4 12h16M4 16.5h10"/>',
    "clock": '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v5l3 1.8"/>',
    "loop": '<path d="M12 4.5a7.5 7.5 0 1 0 7.5 7.5"/><path d="M12 4.5h7.5V12"/>',
    "bars": '<path d="M4.5 16.5V9M9.5 16.5V5M14.5 16.5v-6M19.5 16.5v-9"/>',
    "download": '<path d="M12 4v11M7.5 10.5 12 15l4.5-4.5"/><path d="M5 19.5h14"/>',
}

EN = {
    "lang": "en",
    "dir_depth": 0,
    "other_href": "zh/",
    "title": "Pakperk — a phone-first arXiv reader",
    "description": (
        "Pakperk is a phone-first arXiv reader built around one interaction: read an "
        "abstract, move into a parsed Introduction with paper-grounded chat, then into "
        "the references that matter."
    ),
    "skip": "Skip to content",
    "nav": [
        ("#flow", "The read"),
        ("#deeper", "Deeper"),
        ("#features", "What it does"),
        ("#stack", "Under the hood"),
        ("#download", "Download"),
    ],
    "lang_label": "Language",
    "this_lang": "EN",
    "other_lang": "中文",
    "badge": "Private test build",
    "h1": "Read the abstract. Then keep going.",
    "lede": (
        "Pakperk is a phone-first arXiv reader built around one interaction. Start at the "
        "abstract, move left into a parsed Introduction and ask the paper questions, then "
        "left again into the references it actually leans on — explained."
    ),
    "cta_primary": "See how it reads",
    "cta_secondary": "Download the APK",
    "hero_caption": "Up and down changes the paper.",
    "shot_alt_abstract": "The Pakperk abstract stage on an Android phone, showing an arXiv paper's title, authors and abstract.",
    "shot_alt_intro": "The Introduction stage, showing the paper's parsed introduction and a question field.",
    "shot_alt_chat": "An answer marked Supported, with three claims, Direct evidence chips and links that open the exact source on page 2.",
    "flow_h2": "One gesture, three stages",
    "flow_lede": (
        "Vertical movement changes the paper. Horizontal movement changes how deep you are "
        "in it. Nothing else to learn."
    ),
    "flow": [
        (
            "Abstract",
            "Move up or down for the next or previous paper. Each card is the real arXiv "
            "record, and the original is always one tap away.",
        ),
        (
            "Introduction",
            "Move left. Pakperk reads the PDF's real structure and lays the introduction out "
            "for a phone. Preparation starts on your first committed move into the stage — "
            "never from scrolling past a card.",
        ),
        (
            "Connections",
            "Move left again. The references the introduction leans on, each with a plain "
            "reason it matters and a link to the original work.",
        ),
    ],
    "deeper_h2": "Two screens deeper",
    "deeper_lede": (
        "The stages that make a paper legible on a phone: the introduction the authors "
        "actually wrote, and what you get back when you question it."
    ),
    "deeper": [
        (
            "Really parsed, not summarised.",
            "This is the introduction section lifted out of the PDF's own structure and "
            "re-set for a phone — not a paraphrase of the abstract. The question field sits "
            "at the bottom of it.",
        ),
        (
            "Ask the paper, not the internet.",
            "Answers stay inside one paper. Every claim carries a Direct evidence chip and "
            "a link that opens the exact source page. When the paper cannot support a "
            "question, the assistant says so instead of guessing.",
        ),
    ],
    "disclaimer": "Screenshots from an Android device. The paper is arXiv:2505.13425.",
    "features_h2": "Built to be lived in",
    "features_lede": (
        "A reader you open on a train, in a queue, or with one hand — and that behaves when "
        "the network does not."
    ),
    "features": [
        (
            "library",
            "Library and To Read",
            "Save a paper to To Read. The change lands on the device immediately and "
            "synchronizes when you are online and signed in. Removing one offers Undo. "
            "Saving never starts a paper's preparation.",
        ),
        (
            "cloud",
            "Cached first, then the network",
            "Pakperk opens cached or bundled metadata before it waits for a request, then "
            "refreshes in place. It remembers the paper you were on, the stage, and the "
            "scroll position.",
        ),
        (
            "lock",
            "Sign in without typing a password",
            "Sign-in opens the system browser and uses the service's identity provider. "
            "Pakperk never asks for a provider password inside the app, and access tokens "
            "stay in memory rather than on disk.",
        ),
        (
            "external",
            "A reader, not a replacement",
            "Every paper keeps its exact arXiv identifier and a link to the source record. "
            "Pakperk reads arXiv; it is not affiliated with arXiv and does not stand in for "
            "the original.",
        ),
        (
            "shield",
            "Quiet by default",
            "Guest reading needs no account. Operational telemetry excludes paper text, "
            "prompts, chat messages, handles, and email. No contacts, no precise location, "
            "no advertising identifier.",
        ),
        (
            "access",
            "Reachable by anyone",
            "Every swipe has a labelled alternative. Light and dark themes, reduced motion, "
            "large text, screen-reader semantics, keyboard focus, and system back navigation "
            "are part of the baseline.",
        ),
    ],
    "stack_h2": "Under the hood",
    "stack_lede": (
        "A deliberately narrow stack, chosen so the reading loop stays fast and the server "
        "stays boring."
    ),
    "tags": [
        "Flutter · iOS &amp; Android",
        "Rust · Axum API",
        "Tokio worker",
        "PostgreSQL 16 + pgvector",
        "GROBID",
        "OpenID Connect",
    ],
    "notes": [
        (
            "lines",
            "Structure, not scraping.",
            "GROBID turns the PDF into real scholarly structure, so the Introduction you "
            "read is the introduction the authors wrote.",
        ),
        (
            "clock",
            "A leased job queue.",
            "Preparation runs as PostgreSQL-leased jobs, so a restart picks the work back up "
            "instead of dropping it.",
        ),
        (
            "loop",
            "One polite arXiv client.",
            "Every request to arXiv goes through a single cached, rate-limited client shared "
            "by the whole backend.",
        ),
        (
            "bars",
            "Capabilities are switches.",
            "Each feature is gated per environment, and the app never advertises a capability "
            "the server has turned off.",
        ),
    ],
    "dl_h2": "Download",
    "dl_lede": (
        "The private test build for Android, published directly by the service operator. "
        "There is no store listing yet."
    ),
    "dl_button": f"Download APK · {APK['size']}",
    "dl_meta": "Version {v} · build {b} · {pkg}".format(
        v=APK["version"], b=APK["build"], pkg=APK["package"]
    ),
    "dl_cards": [
        (
            "Requirements",
            "Android 7.0 (API 24) or newer, on a 64-bit ARM device (arm64-v8a) — which is "
            "every mainstream phone sold in the last several years. This build has no 32-bit "
            "engine, and HarmonyOS NEXT cannot install APKs at all.",
        ),
        (
            "Installing",
            "Your browser or file manager will ask you to allow installing from this source; "
            "that permission is per-app and you can revoke it afterwards. If an older Pakperk "
            "signed with a different key is already installed, uninstall it first.",
        ),
        (
            "What it connects to",
            "This build talks to the private test server, not a production service. Accounts "
            "and the To Read library are on; public discussion is off. Expect test data and "
            "occasional downtime.",
        ),
    ],
    "verify_h3": "Verify what you downloaded",
    "verify_lede": "Compare before you install. The file hash:",
    "verify_cert": "Signing certificate (SHA-256):",
    "verify_cmd": "On a Mac or Linux box:",
    "footer_legal": (
        "Pakperk reads papers hosted on arXiv and is not affiliated with or endorsed by "
        "arXiv or Cornell University. Every paper links back to its original record."
    ),
    "footer_links": [
        ("https://arxiv.org", "arXiv.org"),
        ("#flow", "The read"),
        ("#download", "Download"),
    ],
}

ZH = {
    "lang": "zh-Hans",
    "dir_depth": 1,
    "other_href": "../",
    "title": "Pakperk — 为手机而生的 arXiv 阅读器",
    "description": (
        "Pakperk 是一个为手机而生的 arXiv 阅读器，只有一个核心动作：读摘要，向左进入解析好的"
        "引言并就这篇论文提问，再向左看它真正依赖的参考文献。"
    ),
    "skip": "跳到正文",
    "nav": [
        ("#flow", "怎么读"),
        ("#deeper", "再往里"),
        ("#features", "有什么"),
        ("#stack", "底层"),
        ("#download", "下载"),
    ],
    "lang_label": "语言",
    "this_lang": "中文",
    "other_lang": "EN",
    "badge": "私测版本",
    "h1": "读完摘要，继续往下读。",
    "lede": (
        "Pakperk 是一个为手机而生的 arXiv 阅读器，只有一个核心动作。从摘要开始，向左进入解析好的"
        "引言并就这篇论文提问，再向左，看这篇论文真正依赖的那些参考文献——并附上解释。"
    ),
    "cta_primary": "看它怎么读",
    "cta_secondary": "下载 APK",
    "hero_caption": "上下滑动切换论文。",
    "shot_alt_abstract": "Pakperk 的摘要阶段，显示一篇 arXiv 论文的标题、作者和摘要。",
    "shot_alt_intro": "引言阶段，显示解析后的论文引言和底部的提问输入框。",
    "shot_alt_chat": "一条标记为 Supported 的回答，包含三条结论、Direct 证据标记，以及打开第 2 页精确出处的链接。",
    "flow_h2": "一个手势，三个阶段",
    "flow_lede": "上下滑动换论文，左右滑动换深度。没有别的要学。",
    "flow": [
        (
            "摘要 · Abstract",
            "上下滑动切换上一篇或下一篇。每张卡片都是真实的 arXiv 记录，原文永远只差一次点击。",
        ),
        (
            "引言 · Introduction",
            "向左滑。Pakperk 读取 PDF 的真实结构，把引言重新排成适合手机的版式。只有你真正进入"
            "这个阶段时才会开始解析，划过卡片不会触发。",
        ),
        (
            "关联 · Connections",
            "再向左滑。引言所依赖的参考文献，每条都说明它为什么重要，并链接回原始工作。",
        ),
    ],
    "deeper_h2": "再往里两屏",
    "deeper_lede": "让一篇论文在手机上真正可读的两个阶段：作者写下的那节引言，以及你向它提问时拿回的东西。",
    "deeper": [
        (
            "是真解析，不是概括。",
            "这是从 PDF 自身结构里取出的引言那一节，按手机宽度重新排版，而不是把摘要换个说法。"
            "提问输入框就在它下面。",
        ),
        (
            "向论文提问，而不是向互联网。",
            "回答只在这一篇论文的范围内。每条结论都带 Direct 证据标记，以及一个能打开精确出处"
            "页面的链接。论文支撑不了的问题，它会直接说明，而不是猜。",
        ),
    ],
    "disclaimer": "以上为 Android 设备实拍截图，论文为 arXiv:2505.13425。",
    "features_h2": "经得起天天用",
    "features_lede": "在地铁上、排队时、单手就能翻的阅读器——网络不给力的时候也不会乱。",
    "features": [
        (
            "library",
            "收藏与待读",
            "把论文存进待读列表。改动立刻在本机生效，联网并登录后自动同步。移除时提供撤销。"
            "收藏本身不会触发论文解析。",
        ),
        (
            "cloud",
            "先读缓存，再等网络",
            "Pakperk 先打开缓存或内置的元数据，不等请求返回，然后就地刷新。它记得你停在哪一篇、"
            "哪个阶段、滚到哪个位置。",
        ),
        (
            "lock",
            "登录不用在 App 里输密码",
            "登录会打开系统浏览器，走服务自己的身份提供方。Pakperk 从不在 App 内索要账号密码，"
            "访问令牌只存在内存里，不落盘。",
        ),
        (
            "external",
            "是阅读器，不是替代品",
            "每篇论文都保留精确的 arXiv 标识和指向原始记录的链接。Pakperk 只是读 arXiv，"
            "与 arXiv 没有隶属关系，也不打算替代原文。",
        ),
        (
            "shield",
            "默认安静",
            "游客阅读不需要账号。运行遥测不包含论文正文、提示词、对话内容、用户名和邮箱。"
            "不读通讯录，不要精确位置，没有广告标识符。",
        ),
        (
            "access",
            "谁都能用",
            "每个滑动手势都有带文字标签的替代操作。浅色与深色主题、减弱动效、大号字体、"
            "读屏语义、键盘焦点和系统返回，都是基线的一部分。",
        ),
    ],
    "stack_h2": "底层是什么",
    "stack_lede": "刻意收窄的技术栈，让阅读循环够快，让服务器够无聊。",
    "tags": [
        "Flutter · iOS &amp; Android",
        "Rust · Axum API",
        "Tokio worker",
        "PostgreSQL 16 + pgvector",
        "GROBID",
        "OpenID Connect",
    ],
    "notes": [
        (
            "lines",
            "解析结构，不是爬文本。",
            "GROBID 把 PDF 还原成真正的学术结构，所以你读到的引言就是作者写的那一节。",
        ),
        (
            "clock",
            "带租约的任务队列。",
            "解析跑在 PostgreSQL 租约任务里，重启之后会把活接着做完，而不是丢掉。",
        ),
        (
            "loop",
            "一个克制的 arXiv 客户端。",
            "所有对 arXiv 的请求都走同一个带缓存和限流的客户端，整个后端共用。",
        ),
        (
            "bars",
            "能力都是开关。",
            "每项功能按环境单独控制，App 绝不会把服务器上关掉的能力说成可用。",
        ),
    ],
    "dl_h2": "下载",
    "dl_lede": "私测版 Android 安装包，由服务运营者直接发布。目前还没有应用商店上架。",
    "dl_button": f"下载 APK · {APK['size']}",
    "dl_meta": "版本 {v} · build {b} · {pkg}".format(
        v=APK["version"], b=APK["build"], pkg=APK["package"]
    ),
    "dl_cards": [
        (
            "运行要求",
            "Android 7.0（API 24）及以上，且为 64 位 ARM 设备（arm64-v8a）——近几年的主流手机都是。"
            "这个包不含 32 位引擎；鸿蒙 NEXT 无法安装 APK。",
        ),
        (
            "安装方式",
            "浏览器或文件管理器会要求你允许安装来自此来源的应用；该权限是按应用授予的，装完可以收回。"
            "如果机器上已装过用不同签名的 Pakperk，需要先卸载。",
        ),
        (
            "它连到哪里",
            "这个版本连的是私测服务器，不是正式服务。账号和待读列表是开的，公开讨论是关的。"
            "数据是测试数据，偶尔会停机。",
        ),
    ],
    "verify_h3": "核对你下到的文件",
    "verify_lede": "安装前比对一下。文件哈希：",
    "verify_cert": "签名证书（SHA-256）：",
    "verify_cmd": "在 Mac 或 Linux 上：",
    "footer_legal": (
        "Pakperk 阅读托管在 arXiv 上的论文，与 arXiv 及康奈尔大学没有隶属或背书关系。"
        "每篇论文都链接回它的原始记录。"
    ),
    "footer_links": [
        ("https://arxiv.org", "arXiv.org"),
        ("#flow", "怎么读"),
        ("#download", "下载"),
    ],
}


def icon(name: str, cls: str = "card__icon") -> str:
    return (
        f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{ICONS[name]}</svg>'
    )


def render(c: dict) -> str:
    base = "../" * c["dir_depth"]
    dl_href = f"{base}download/{APK['file']}"

    nav = "\n          ".join(
        f'<a href="{href}">{html.escape(label)}</a>' for href, label in c["nav"]
    )

    flow_cards = "\n".join(
        f"""            <article class="card reveal" style="--i: {i}">
              <span class="step__index tnum" aria-hidden="true">{i + 1}</span>
              <h3 class="title">{html.escape(t)}</h3>
              <p class="body">{html.escape(b)}</p>
            </article>"""
        for i, (t, b) in enumerate(c["flow"])
    )

    feature_cards = "\n".join(
        f"""            <article class="card reveal" style="--i: {i % 3}">
              {icon(ic)}
              <h3 class="title">{html.escape(t)}</h3>
              <p class="body">{html.escape(b)}</p>
            </article>"""
        for i, (ic, t, b) in enumerate(c["features"])
    )

    tags = "\n            ".join(
        f'<span class="tag reveal" style="--i: {i}">{t}</span>'
        for i, t in enumerate(c["tags"])
    )

    notes = "\n".join(
        f"""            <li class="reveal" style="--i: {i}">
              {icon(ic, "note__icon")}
              <span><b>{html.escape(lead)}</b> {html.escape(rest)}</span>
            </li>"""
        for i, (ic, lead, rest) in enumerate(c["notes"])
    )

    dl_cards = "\n".join(
        f"""            <article class="card reveal" style="--i: {i}">
              <h3 class="title">{html.escape(t)}</h3>
              <p class="body">{html.escape(b)}</p>
            </article>"""
        for i, (t, b) in enumerate(c["dl_cards"])
    )

    footer_links = "\n          ".join(
        f'<a href="{href}"{" rel=\"noopener noreferrer external\"" if href.startswith("http") else ""}>{html.escape(label)}</a>'
        for href, label in c["footer_links"]
    )

    shots = [
        (f"{base}assets/shots/shot-introduction.webp", c["shot_alt_intro"]),
        (f"{base}assets/shots/shot-chat.webp", c["shot_alt_chat"]),
    ]
    deeper_items = "\n".join(
        f"""            <figure class="showcase__item reveal" style="--i: {i}">
              <div class="phone">
                <img src="{src}" width="600" height="1333" loading="lazy" decoding="async"
                     alt="{html.escape(alt)}" />
              </div>
              <figcaption><b>{html.escape(lead)}</b> {html.escape(rest)}</figcaption>
            </figure>"""
        for i, ((src, alt), (lead, rest)) in enumerate(zip(shots, c["deeper"]))
    )

    return f"""<!doctype html>
<html lang="{c['lang']}">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{html.escape(c['title'])}</title>
    <meta name="description" content="{html.escape(c['description'])}" />
    <meta name="robots" content="noindex, nofollow" />
    <meta name="theme-color" content="#f7f4ec" media="(prefers-color-scheme: light)" />
    <meta name="theme-color" content="#17211b" media="(prefers-color-scheme: dark)" />
    <meta property="og:type" content="website" />
    <meta property="og:title" content="{html.escape(c['title'])}" />
    <meta property="og:description" content="{html.escape(c['description'])}" />
    <meta property="og:image" content="{base}assets/pakperk_app_icon.png" />
    <link rel="icon" href="{base}assets/pakperk_app_icon.svg" type="image/svg+xml" />
    <link rel="apple-touch-icon" href="{base}assets/pakperk_app_icon.png" />
    <link rel="alternate" hreflang="en" href="/site/" />
    <link rel="alternate" hreflang="zh-Hans" href="/site/zh/" />
    <link rel="preload" as="image" href="{base}assets/shots/shot-abstract.webp" />
    <link rel="stylesheet" href="{base}styles.css" />
    <script src="{base}app.js" defer></script>
  </head>
  <body>
    <a class="skip" href="#main">{html.escape(c['skip'])}</a>

    <svg width="0" height="0" aria-hidden="true" focusable="false" style="position: absolute">
      <symbol id="mark" viewBox="0 0 512 512">
        <path fill="var(--mark-cover)" d="M246 112c-47-29-112-32-166-8a20 20 0 0 0-12 18v254a20 20 0 0 0 28 18c46-20 101-17 150 12V112Z"/>
        <path fill="var(--mark-cover)" d="M266 112c47-29 112-32 166-8a20 20 0 0 1 12 18v254a20 20 0 0 1-28 18c-46-20-101-17-150 12V112Z"/>
        <path fill="var(--mark-page)" d="M225 148c-37-17-84-19-124-6v210c40-11 84-6 124 12V148Zm62 0c37-17 84-19 124-6v210c-40-11-84-6-124 12V148Z"/>
        <path fill="var(--mark-spine)" d="M256 116 283 93v272l-27 34-27-34V93l27 23Z"/>
      </symbol>
    </svg>

    <header class="topbar">
      <div class="shell topbar__inner">
        <a class="wordmark" href="#main">
          <svg class="mark" role="img" aria-label="Pakperk"><use href="#mark" /></svg>
          Pakperk
        </a>
        <nav class="topnav" aria-label="{html.escape(c['lang_label'])}">
          {nav}
        </nav>
        <div class="langswitch" role="group" aria-label="{html.escape(c['lang_label'])}">
          <span aria-current="page">{c['this_lang']}</span>
          <a href="{c['other_href']}">{c['other_lang']}</a>
        </div>
      </div>
    </header>

    <main id="main">
      <section class="hero">
        <div class="shell hero__grid">
          <div class="hero__copy">
            <span class="badge reveal" style="--i: 0">
              <span class="badge__dot" aria-hidden="true"></span>
              <span class="overline">{html.escape(c['badge'])}</span>
            </span>
            <h1 class="display reveal" style="--i: 1">{html.escape(c['h1'])}</h1>
            <p class="lede reveal" style="--i: 2">{html.escape(c['lede'])}</p>
            <div class="hero__actions reveal" style="--i: 3">
              <a class="btn btn--primary" href="#flow">
                {html.escape(c['cta_primary'])}
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <path d="M5 12h13M13 6l6 6-6 6" />
                </svg>
              </a>
              <a class="btn btn--quiet" href="#download">{html.escape(c['cta_secondary'])}</a>
            </div>
          </div>

          <figure class="hero__device reveal" style="--i: 2">
            <div class="phone phone--lead">
              <img src="{base}assets/shots/shot-abstract.webp" width="600" height="1333"
                   fetchpriority="high" decoding="async"
                   alt="{html.escape(c['shot_alt_abstract'])}" />
            </div>
            <figcaption class="device__caption">
              <svg class="bob" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 4.5v15M8 8.5l4-4 4 4M8 15.5l4 4 4-4" />
              </svg>
              {html.escape(c['hero_caption'])}
            </figcaption>
          </figure>
        </div>
      </section>

      <section id="flow" class="band">
        <div class="shell">
          <div class="section-head">
            <span class="rule reveal" aria-hidden="true"></span>
            <h2 class="headline reveal" style="--i: 1">{html.escape(c['flow_h2'])}</h2>
            <p class="lede reveal" style="--i: 2">{html.escape(c['flow_lede'])}</p>
          </div>
          <div class="grid stagecycle">
{flow_cards}
          </div>
        </div>
      </section>

      <section id="deeper">
        <div class="shell">
          <div class="section-head">
            <span class="rule reveal" aria-hidden="true"></span>
            <h2 class="headline reveal" style="--i: 1">{html.escape(c['deeper_h2'])}</h2>
            <p class="lede reveal" style="--i: 2">{html.escape(c['deeper_lede'])}</p>
          </div>
          <div class="showcase">
{deeper_items}
          </div>
          <p class="disclaimer reveal">{html.escape(c['disclaimer'])}</p>
        </div>
      </section>

      <section id="features" class="band">
        <div class="shell">
          <div class="section-head">
            <span class="rule reveal" aria-hidden="true"></span>
            <h2 class="headline reveal" style="--i: 1">{html.escape(c['features_h2'])}</h2>
            <p class="lede reveal" style="--i: 2">{html.escape(c['features_lede'])}</p>
          </div>
          <div class="grid">
{feature_cards}
          </div>
        </div>
      </section>

      <section id="stack">
        <div class="shell">
          <div class="section-head">
            <span class="rule reveal" aria-hidden="true"></span>
            <h2 class="headline reveal" style="--i: 1">{html.escape(c['stack_h2'])}</h2>
            <p class="lede reveal" style="--i: 2">{html.escape(c['stack_lede'])}</p>
          </div>
          <div class="stack">
            {tags}
          </div>
          <ul class="notes">
{notes}
          </ul>
        </div>
      </section>

      <section id="download" class="band">
        <div class="shell">
          <div class="section-head">
            <span class="rule reveal" aria-hidden="true"></span>
            <h2 class="headline reveal" style="--i: 1">{html.escape(c['dl_h2'])}</h2>
            <p class="lede reveal" style="--i: 2">{html.escape(c['dl_lede'])}</p>
          </div>

          <div class="download reveal">
            <a class="btn btn--primary btn--lg" href="{dl_href}" download>
              {icon('download', 'btn__icon')}
              {html.escape(c['dl_button'])}
            </a>
            <p class="download__meta tnum">{html.escape(c['dl_meta'])}</p>
          </div>

          <div class="grid">
{dl_cards}
          </div>

          <div class="verify reveal">
            <h3 class="title">{html.escape(c['verify_h3'])}</h3>
            <p class="body">{html.escape(c['verify_lede'])}</p>
            <p class="hash tnum">{APK['sha256']}</p>
            <p class="body">{html.escape(c['verify_cert'])}</p>
            <p class="hash tnum">{APK['cert']}</p>
            <p class="body">{html.escape(c['verify_cmd'])}</p>
            <p class="hash">shasum -a 256 {APK['file']}</p>
          </div>
        </div>
      </section>
    </main>

    <footer class="footer">
      <div class="shell footer__inner">
        <div>
          <a class="wordmark" href="#main">
            <svg class="mark" role="img" aria-label="Pakperk"><use href="#mark" /></svg>
            Pakperk
          </a>
          <p class="footer__legal">{html.escape(c['footer_legal'])}</p>
        </div>
        <nav class="footer__links" aria-label="Pakperk">
          {footer_links}
        </nav>
      </div>
    </footer>
  </body>
</html>
"""


def main() -> None:
    (HERE / "index.html").write_text(render(EN), encoding="utf-8")
    zh_dir = HERE / "zh"
    zh_dir.mkdir(exist_ok=True)
    (zh_dir / "index.html").write_text(render(ZH), encoding="utf-8")
    print("wrote landing/index.html and landing/zh/index.html")


if __name__ == "__main__":
    main()
