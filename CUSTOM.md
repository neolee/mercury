[English](#english-version) | [中文](#chinese-version)

<a id="english-version"></a>

# Mercury Customization Guide

## What This Guide Covers

Mercury currently supports two kinds of user customization:
- AI agent prompt templates
- Digest sharing and export templates

This guide does not try to list every internal detail. It focuses on the questions that matter most in actual use:
- Where custom files are stored
- How to create your own copy from a built-in template
- What happens if a custom file is broken
- Which template parts are only styling, and which are structural contracts
- What beginners can safely edit first, and what should not be changed too early

If you are just getting started, begin with Quick Start. If you already have some experience and want to customize templates more deeply, read the whole guide.

## Quick Start

### Customize AI Agent Prompts

1. Open Mercury and go to Settings.
2. Open Agents.
3. In the Agents list, choose Summary, Translation, or Tagging.
4. Click custom prompts.
5. Mercury opens the folder containing your custom file so you can edit it. If the file does not exist yet, Mercury creates it automatically.

### Customize Digest Templates

1. Open Mercury and go to Settings.
2. Open Digest.
3. In the Templates section, choose the item you want to customize:
   - Share Digest
   - Export Digest
   - Export Multiple Digest
4. Click custom template.
5. Mercury opens the folder containing your custom file so you can edit it. If the file does not exist yet, Mercury creates it automatically.

### Restore the Default Behavior

The simplest way is not to undo your edits, but to delete the custom file directly. Mercury will then continue using the built-in template. If you want to customize it again later, just repeat the same process.

## Where Custom Files Are Stored

Mercury stores custom files inside the app sandbox, usually under `$HOME/Library/Containers/net.paradigmx.Mercury/Data/Library/Application Support/Mercury`. In practice, you usually do not need to locate this directory yourself, because Mercury can create the custom files in the correct place for you.

### AI Agent Prompts

Location: the `Agent/Prompts/` subdirectory under the path above

File names:
- `summary.yaml`
- `translation.yaml`
- `tagging.yaml`

Built-in templates:
- `summary.default.yaml`
- `translation.default.yaml`
- `tagging.default.yaml`

### Digest Templates

Location: the `Digest/Templates/` subdirectory under the path above

File names:
- `single-text.yaml`: Share Digest
- `single-markdown.yaml`: Export Digest
- `multiple-markdown.yaml`: Export Multiple Digest

These are your personal custom files. Mercury will not overwrite an existing custom file when the app is updated.

## What Happens If a File Is Broken

If a custom file cannot be loaded correctly, Mercury automatically falls back to the built-in version and shows a notice in the UI.
- Your custom file is not deleted.
- The related feature remains usable.
- You can fix the file and keep using it.

## Understanding Template Contracts

When editing Mercury templates, the most important thing is not syntax alone. You first need to distinguish between two kinds of things:
- Presentation styling: usually safe to change more freely
- Structural contracts: tied to feature behavior, and should not be treated as plain text fragments

The most common problem is not changing wording incorrectly. It is accidentally breaking an important structural contract.

## Suggestions for Customizing AI Agent Prompts

### Safe First Edits

If this is your first time editing AI agent prompts, start with small changes like these:
- Adjust the tone, for example to make it more concise, more academic, or more conversational
- Adjust summary length or bullet count
- Add style requirements for translation
- Make Tagging more conservative so it guesses less or prefers reusing existing tags

### What Not to Change Too Early

- Do not casually delete placeholders such as `{{sourceText}}` or `{{targetLanguageDisplayName}}`
- Do not weaken hard constraints such as “output JSON only” or “output the translation only” too much
- Do not make Tagging output extra unstructured prose, or later parsing may fail

### The Three Prompt Types

#### Summary

The Summary prompt is the most structurally complex of the three. It defines not only tone, but also output contracts for different detail levels.

Using the default template's `medium` detail level as an example, the output has three parts:
- Opening: a one-sentence summary
- List: 3-5 key points
- Closing: emphasis on practical significance and value

If you only want to change style, start with:
- How the opening sentence is phrased
- The tone and formatting of the list
- How the closing part is emphasized

If you want to change length ranges, you can also adjust the ranges in `defaultParameters`. But keep the differences between short, medium, and detailed meaningful. Do not make the three levels almost the same.

#### Translation

The Translation prompt is the simplest. Its core goal is faithful translation, with translation output only.

Good kinds of edits:
- Specify a more formal or more natural translation style
- Add terminology preservation rules
- Specify how proper nouns should be handled

It is usually a bad idea to change constraints like “Output the translation only”, because that often causes explanatory text to leak into the output.

#### Tagging

The Tagging prompt is essentially a high-precision, low-guessing classifier. It has the strictest output format requirements.

Good kinds of edits:
- Make it more conservative, so tags are returned only when evidence is very clear
- Adjust the maximum number of new tags
- Add your own tag preference rules

It is usually a bad idea to change:
- The requirement to return only a JSON array
- The constraints against overly broad or generic tags

## Digest Template Basics

Digest templates are not plain static Markdown text. They are templates with placeholders and sections, and many fragments you see are actually feature switches.

The three Digest templates serve different purposes:
- `single-text.yaml`: generates single-line plain text for sharing
- `single-markdown.yaml`: exports a Markdown digest for one article
- `multiple-markdown.yaml`: exports a Markdown digest for multiple articles

### Safest Beginner Edits

If this is your first time editing Digest templates, start with changes like these:
- Change label wording such as `{{labelSource}}`, `{{labelAuthor}}`, or `{{labelNote}}`
- Change heading levels, for example from `##` to `###`
- Change the Markdown styling of the summary block or note block
- Add stable fields to the front matter block

These kinds of edits usually do not break structural contracts.

## Structural Contracts in Digest Templates

Digest templates contain many structural contracts. Understanding them is important if you want to customize templates safely.

### 1. `includeSummary` and `summaryTextBlockquote` form one contract

For example, the built-in template contains this structure:

```text
{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}
```

In these three lines, the real behavior control is the `{{#includeSummary}}...{{/includeSummary}}` section wrapper.
- The `includeSummary` section wrapper defines a conditional section: its value decides whether the wrapped block is output
- `summaryTextBlockquote` is the prepared summary content
- The leading `>` is only Markdown styling for a blockquote

Usually you should change the appearance, not contracts such as `includeSummary` or `summaryTextBlockquote`.

For example, this version is safe:

```text
{{#includeSummary}}
### Summary

{{summaryTextBlockquote}}
{{/includeSummary}}
```

This changes the summary from a blockquote into a normal section with a heading, while still preserving the behavior that the whole block only appears when a summary exists.

This is not recommended:

```text
### Summary

{{summaryTextBlockquote}}
```

Because you removed `includeSummary`. At a glance it only looks like two lines were removed, but the template no longer checks whether the summary block should be shown. Instead it always outputs the heading above, while `summaryTextBlockquote` may be empty. The result is an empty Summary heading, which is usually not what you want.

### 2. `includeNote` and `noteText` form another contract

The built-in template usually looks like this:

```text
{{#includeNote}}
**{{labelNote}}**: {{noteText}}
{{/includeNote}}
```

Here:
- `includeNote` controls whether the whole note block appears
- `noteText` is the note content written by the user
- `labelNote` is the note label text

You can freely change `labelNote`, and you can also change the layout, for example:

```text
{{#includeNote}}
### My Note

{{noteText}}
{{/includeNote}}
```

But you should not delete the `includeNote` section wrapper.

### 3. `entries` is not a normal placeholder, but a repeated block

In `multiple-markdown.yaml`, this structure decides that one block is repeated for each article:

```text
{{#entries}}
## {{articleTitle}}

**{{labelSource}}**: [{{articleTitle}}]({{articleURL}})<br>
**{{labelAuthor}}**: {{articleAuthor}}

{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}

{{#includeNote}}
**{{labelNote}}**: {{noteText}}
{{/includeNote}}
{{/entries}}
```

Here, `entries` is not “some field”. It is another kind of section wrapper that defines looping behavior. During output, the entire wrapped block is repeated once for each article.

You can change the styling inside the block, but in general you should not:
- Delete `{{#entries}}` or `{{/entries}}`
- Move content that belongs to a single article outside the repeated block

Safe example:

```text
{{#entries}}
### {{articleTitle}}

- Link: [{{articleTitle}}]({{articleURL}})
- Author: {{articleAuthor}}

{{#includeSummary}}
Summary:

{{summaryTextBlockquote}}
{{/includeSummary}}

{{#includeNote}}
Note:

{{noteText}}
{{/includeNote}}
{{/entries}}
```

This only rearranges the styling of each article block. It does not break the repetition logic.

### 4. Front matter placeholders are usually not decoration

In Markdown export templates, the front matter at the top may look like this:

```text
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
+++
```

Among these fields, pay special attention to at least:
- `digestTitle`
- `fileSlug`
- `exportDateTimeISO8601`

These values are usually not there for appearance. They provide stable metadata for the exported file.

You can:
- Change field order
- Add your own static fields
- Use a different key name for the same placeholder

For example:

```text
+++
date = '{{exportDateTimeISO8601}}'
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
source = 'Mercury'
layout = 'digest'
+++
```

But deleting `digestTitle` or `fileSlug` directly is usually a bad idea unless you are very sure your downstream tools do not depend on them.

## Positive Examples

### Example 1: Change the note label wording

Original:

```text
{{#includeNote}}
**{{labelNote}}**: {{noteText}}
{{/includeNote}}
```

You can change only the default parameter:

```yaml
defaultParameters:
  - labelNote=My Notes
```

Or directly change the layout:

```text
{{#includeNote}}
**Personal Note**

{{noteText}}
{{/includeNote}}
```

### Example 2: Change the summary from a blockquote to a headed section

Original:

```text
{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}
```

Revised:

```text
{{#includeSummary}}
## Summary

{{summaryTextBlockquote}}
{{/includeSummary}}
```

This keeps `includeSummary` in place and only changes the display style from a blockquote to a normal Markdown block.

### Example 3: Add stable fields to exported front matter

```text
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
generator = 'Mercury'
content_type = 'digest'
+++
```

This is usually safe because it only adds static metadata.

### Example 4: Lightly restyle each entry in multi-article export

```text
{{#entries}}
### {{articleTitle}}

Source: [{{articleTitle}}]({{articleURL}})
Author: {{articleAuthor}}

{{#includeSummary}}
{{summaryTextBlockquote}}
{{/includeSummary}}

{{#includeNote}}
Note: {{noteText}}
{{/includeNote}}
{{/entries}}
```

This kind of change is mainly about presentation, not behavior.

## Negative Examples

### Example 1: Removing the section wrapper

```text
> {{summaryTextBlockquote}}
```

This removes:

```text
{{#includeSummary}}
...
{{/includeSummary}}
```

That erases the structural contract that controls whether the summary block exists.

### Example 2: Breaking the repeated structure in multi-article export

```text
## {{articleTitle}}

{{#entries}}
{{summaryTextBlockquote}}
{{/entries}}
```

This puts a per-article title outside the repeated block, which changes the repetition boundary of the template. The result is usually not just a different layout, but incorrect or confusing output.

### Example 3: Making the Tagging prompt output explanatory text

For example, changing “return only a JSON array” into:

```text
First explain your reasoning, then output a JSON array.
```

This can easily break later parsing, because the Tagging consumer expects pure JSON.

## Practical Advice for Beginners

If you have not customized templates before, this is a good order to follow:

1. Change wording first, without changing structure.
2. Then change Markdown styling, such as heading levels, bold text, or blockquotes.
3. Confirm that export or sharing still works correctly.
4. Only after that, try changing section boundaries, front matter organization, or prompt constraint strength.

In one sentence: change how it looks first, then change the structure that controls behavior. If you run into problems, you can always [ask here](https://github.com/neolee/mercury/issues).

### Editor and Formatting Tips

- These files are all YAML. Use an editor with YAML highlighting if possible.
- If something stops working after an edit, first check indentation and whether your structural blocks are still complete.
- For Digest templates, check whether pairs such as `{{#sectionName}}` and `{{/sectionName}}` still match.
- For prompt templates, check whether placeholder names are spelled correctly.

### Returning to the Built-in Template

You can abandon your custom version at any time by deleting the corresponding custom file. Mercury will automatically use the built-in template again. If you later click customize again, Mercury will create a fresh default copy for you.

---

<a id="chinese-version"></a>

# Mercury 自定义指南

## 这份文档解决什么问题

Mercury 目前支持两类用户自定义：
- AI 智能体的 **提示词**（*prompt*）模板
- **文摘**（*digest*）的分享与输出模板

这份指南不追求把所有内部实现细节都列出来，而是优先回答几个对实际使用最重要的问题：
- 自定义文件到底放在哪里
- 怎样从内置模板生成自己的副本
- 文件写坏了之后会发生什么
- 哪些模板片段只是样式，哪些其实是功能契约
- 初学者适合先改什么，哪些地方最好不要一上来就动

如果你刚开始尝试，建议先看“快速开始”；有一些经验之后，你可能需要深入了解模板结构与契约，这时建议完整看完整份指南。

## 快速开始

### 自定义 AI 智能体提示词

1. 打开 Mercury 的“设置”。
2. 进入“智能体”。
3. 在“智能体”列表中选择要定制的 **摘要**、**翻译** 或 **自动标签**。
4. 点击右侧的 **自定义提示词**。
5. Mercury 会打开你的自定义文件所在目录，方便你编辑它。如果文件还不存在，Mercury 会自动帮你创建它。

### 自定义文摘模板

1. 打开 Mercury 的“设置”。
2. 进入 **文摘** 页面。
3. 在 **模板定制** 区域中选择你想定制的项目：
   - 分享文摘
   - 导出文摘
   - 导出多条文摘
4. 点击对应的“自定义模板”。
5. Mercury 会打开你的自定义文件所在目录，方便你编辑它。如果文件还不存在，Mercury 会自动帮你创建它。

### 想恢复默认行为

最简单的方法不是“撤销编辑”，而是直接删除你的自定义文件。下次 Mercury 会继续使用内置模板。如果你又想定制了，重复上面的过程即可。

## 自定义文件在哪里

Mercury 的自定义文件存放在应用沙箱中，通常是在 `$HOME/Library/Containers/net.paradigmx.Mercury/Data/Library/Application Support/Mercury` 目录下。因为 Mercury 的设置界面会自动帮你在正确的位置创建自定义文件，所以你通常不需要自己去找这个目录。

### AI 智能体提示词

位置：上述目录下的 `Agent/Prompts/` 子目录

文件名：
- `summary.yaml`
- `translation.yaml`
- `tagging.yaml`

对应内置模板：
- `summary.default.yaml`
- `translation.default.yaml`
- `tagging.default.yaml`

### 文摘模板

位置：上述目录下的 `Digest/Templates/` 子目录

文件名：
- `single-text.yaml`：Share Digest
- `single-markdown.yaml`：Export Digest
- `multiple-markdown.yaml`：Export Multiple Digest

这些文件都是你个人版本的自定义文件。Mercury 升级时不会改写你已经存在的自定义文件。

## 文件写坏了会怎样

如果你的自定义文件无法被正确加载，Mercury 会自动退回到内置版本，同时在界面上显示相关提示。
- 你的自定义文件不会被删除。
- 相关功能仍可继续使用。
- 你可以修好这个文件后继续使用。

## 理解“模板契约”

编辑 Mercury 模板时，最重要的不是语法，而是先区分两种东西：
- 展示样式：通常可以比较自由地改
- 结构契约：和功能行为绑定，不能只按“看起来像普通文本”来理解

最常见的问题，不是把文案改错，而是把某个关键性的结构契约破坏了。

## AI 智能体提示词自定义建议

### 适合先改什么

如果你第一次改 AI 智能体提示词，建议优先做这几类小改动：
- 调整语气，比如更简洁、更学术、更口语化
- 调整摘要长度或列表项（*bullet*）数量
- 给翻译增加额外风格要求
- 调整自动标签的保守程度，让它更少猜测或更偏向复用已有标签

### 不建议一开始就改什么

- 不要随意删除模板里的占位符，例如 `{{sourceText}}`、`{{targetLanguageDisplayName}}`
- 不要把要求“只输出 JSON”“只输出翻译结果”之类的硬约束改得太松
- 不要在自动标签提示词里引入额外非结构化的输出，否则可能破坏解析流程

### 三类提示词的定位

#### 摘要

**摘要** 提示词是三者里结构最复杂的。它不仅定义语气，还定义不同详细程度（*detail level*）的输出契约。

以默认模板的 `medium` 详细程度的要求为例，这部分输出分三部分，分别是：
- 开头：一句话概要
- 列表：3-5 个要点
- 总结：重点放在现实意义和价值说明

如果你只是想改风格，优先改：
- 开头句的表述方式
- 列表的语气和格式
- 总结部分的强调方式

如果你想改长度范围，也可以调 `defaultParameters` 里的区间值，但要尽量保持 short / medium / detailed 三档的层次差异，不要把三档改成几乎一样。

#### 翻译

**翻译** 提示词最简单，核心目标就是“忠实翻译，且只输出翻译结果”。

适合的改法：
- 指定更偏书面或更偏自然的译风
- 指定术语保留策略
- 指定对专有名词的处理方式

不建议改动“Output the translation only”这类约束，否则容易让输出夹带说明文字。

#### 自动标签

**自动标签** 提示词本质上是一个“高精度、低猜测”的分类器。它对输出格式要求最严格。

适合的改法：
- 让它更保守，只在证据非常明确时出标签
- 调整新标签数量上限
- 增加你自己的标签偏好原则

不建议改动：
- “只返回 JSON 数组”的要求
- 放宽对过于宽泛标签（*broad / generic tag*）的约束

## 文摘模板基础

文摘模板不是普通的静态 Markdown 文本，而是带占位符和分节（*section*）的模板。你看到的很多片段其实代表功能开关。

三个文摘模板的定位分别是：
- `single-text.yaml`：给分享动作生成单行纯文本
- `single-markdown.yaml`：导出单篇文章的 Markdown 文摘
- `multiple-markdown.yaml`：导出多篇文章的 Markdown 文摘

### 最安全的入门改法

如果你第一次改文摘模板，优先做这些修改：
- 修改标签文案，比如 `{{labelSource}}`、`{{labelAuthor}}`、`{{labelNote}}`
- 调整标题层级，比如把 `##` 改成 `###`
- 调整摘要块或笔记块的 Markdown 外观
- 在开头的元数据（front matter）区里增加新的稳定字段

这些改动通常不会破坏结构契约。

## 文摘模板的结构契约

文摘模板中有大量的结构性契约，理解它们对于正确定制模板至关重要。

### 1. `includeSummary` 和 `summaryTextBlockquote` 是一组契约

例如内置模板里有这样的结构：

```text
{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}
```

这三行里，真正控制行为的是 `{{#includeSummary}}...{{/includeSummary}}` 这个 **分节器**（*section wrapper*）。
- `includeSummary` 分节器定义了一种“条件选择”分节，它的值决定是否输出它包裹的这个小节
- 里面的 `summaryTextBlockquote` 是已经准备好的摘要内容
- 前面的 `>` 只是 Markdown 样式，表示引用块（blockquote）

通常你应该改的是外观，而不是 `includeSummary`、`summaryTextBlockquote` 这样的契约（*existence contract*）。

例如下面这种改法是安全的：

```text
{{#includeSummary}}
### Summary

{{summaryTextBlockquote}}
{{/includeSummary}}
```

这表示你把摘要从引用块改成了带标题的普通段落，但依然保留了“有摘要才显示整个块”的行为。

不建议这样改：

```text
### Summary

{{summaryTextBlockquote}}
```

因为你把 `includeSummary` 去掉了。这样看上去只是少了两行，但模板不再判断“是否输出摘要块”的设置，而是固定输出上面的段落，但是 `summaryTextBlockquote` 内容可能是空的，结果就是输出一个空的 Summary 标题，这通常不是你想要的。

### 2. `includeNote` 和 `noteText` 也是一组契约

内置模板里通常是这样：

```text
{{#includeNote}}
**{{labelNote}}**: {{noteText}}
{{/includeNote}}
```

这里：
- `includeNote` 控制整段笔记是否出现
- `noteText` 是用户写下的笔记内容
- `labelNote` 是笔记标签文案

你可以自由改 `labelNote`，也可以改变这段的排版，比如改成：

```text
{{#includeNote}}
### 我的备注

{{noteText}}
{{/includeNote}}
```

但不应该把 `includeNote` 这个分节器删掉。

### 3. `entries` 不是普通占位符，而是重复块

在 `multiple-markdown.yaml` 中，这段结构决定了“每篇文章重复输出一次”：

```text
{{#entries}}
## {{articleTitle}}

**{{labelSource}}**: [{{articleTitle}}]({{articleURL}})<br>
**{{labelAuthor}}**: {{articleAuthor}}

{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}

{{#includeNote}}
**{{labelNote}}**: {{noteText}}
{{/includeNote}}
{{/entries}}
```

这里的 `entries` 不是“某个字段”，而是另一种分节器，它定义了一种循环迭代的行为，在输出时对每篇文章重复这一整个分节的内容。

你可以改块内部的样式，但一般不要：
- 删掉 `{{#entries}}` 或 `{{/entries}}`
- 把只属于单篇文章的内容挪到重复块外面

安全示例：

```text
{{#entries}}
### {{articleTitle}}

- Link: [{{articleTitle}}]({{articleURL}})
- Author: {{articleAuthor}}

{{#includeSummary}}
Summary:

{{summaryTextBlockquote}}
{{/includeSummary}}

{{#includeNote}}
Note:

{{noteText}}
{{/includeNote}}
{{/entries}}
```

这只是重排了单篇条目的样式，没有破坏重复逻辑。

### 4. front matter 占位符通常不是装饰

在 Markdown 导出模板里，最前面的元数据（*front matter*）如：

```text
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
+++
```

这里的几个字段里，至少要特别注意：
- `digestTitle`
- `fileSlug`
- `exportDateTimeISO8601`

这些值通常不是为了好看，而是给导出的文件提供稳定元数据。

你可以：
- 改字段顺序
- 加自己的静态字段
- 用别的键名承载同一个占位符

例如：

```text
+++
date = '{{exportDateTimeISO8601}}'
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
source = 'Mercury'
layout = 'digest'
+++
```

但不建议直接删掉 `digestTitle` 或 `fileSlug`，除非你非常确定自己的下游工具不依赖这些信息。

## 正面示例

### 示例 1：修改笔记标签文案

原始写法：

```text
{{#includeNote}}
**{{labelNote}}**: {{noteText}}
{{/includeNote}}
```

你可以只改默认参数：

```yaml
defaultParameters:
  - labelNote=My Notes
```

也可以直接改模板排版：

```text
{{#includeNote}}
**Personal Note**

{{noteText}}
{{/includeNote}}
```

### 示例 2：把摘要从引用块改成标题段落

原始写法：

```text
{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}
```

修改：

```text
{{#includeSummary}}
## Summary

{{summaryTextBlockquote}}
{{/includeSummary}}
```

这里保留了 `includeSummary`，只是把展示风格从引用块改成普通 Markdown 区块。

### 示例 3：在导出 front matter 中加入稳定字段

```text
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
generator = 'Mercury'
content_type = 'digest'
+++
```

这种改法通常很安全，因为它只是增加静态元数据。

### 示例 4：轻量重排多篇导出的单条样式

```text
{{#entries}}
### {{articleTitle}}

Source: [{{articleTitle}}]({{articleURL}})
Author: {{articleAuthor}}

{{#includeSummary}}
{{summaryTextBlockquote}}
{{/includeSummary}}

{{#includeNote}}
Note: {{noteText}}
{{/includeNote}}
{{/entries}}
```

这类改动本质上是换样式，不是改行为。

## 反面示例（不要这样改！）

### 反例 1：去掉分节器

```text
> {{summaryTextBlockquote}}
```

删掉了：

```text
{{#includeSummary}}
...
{{/includeSummary}}
```

这样会把“摘要块是否存在”的结构契约抹掉。

### 反例 2：破坏多篇导出的迭代结构

```text
## {{articleTitle}}

{{#entries}}
{{summaryTextBlockquote}}
{{/entries}}
```

这类改法把单条文章标题放到了重复块外面，等于改变了模板的重复边界。结果通常不是你想要的版式，而是逻辑错误或输出混乱。

### 反例 3：把自动标签提示词改成输出解释文字

例如把“只输出 JSON 数组”改成：

```text
First explain your reasoning, then output a JSON array.
```

这很容易让 Mercury 后续解析失败，因为自动标签的消费方期待的是纯 JSON。

## 给新手的实用建议

如果你之前没怎么改过模板，建议按这个顺序来：

1. 尝试修改文案，不改结构。
2. 尝试改 Markdown 样式，比如标题层级、粗体、引用块。
3. 确认导出或分享行为仍然正常。
4. 最后再尝试改分节的内外边界、元数据字段组织、提示词约束强度等。

一句话总结：先改“看起来的样子”，后改“决定行为的结构”。如果遇到问题，也欢迎[随时提问](https://github.com/neolee/mercury/issues)。

### 编辑器和格式建议

- 这些文件都是 YAML，建议使用支持 YAML 高亮的编辑器。
- 改完后如果功能出现异常，先检查缩进和成对的结构契约是否完整。
- 对文摘模板，重点检查 `{{#...}}` 和 `{{/...}}` 是否仍然成对。
- 对提示词模板，重点检查占位符名有没有拼错。

### 回退到默认模板

随时可以放弃自己的自定义修改，直接删除对应自定义文件即可，Mercury 会自动使用内置模板；当你再次点击“自定义”时，它会重新复制一份新的默认副本供你定制。