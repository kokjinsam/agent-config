---
name: diataxis
description: Write, edit, review, or organize customer-facing product documentation using Diátaxis. Use for tutorials, task guides, help-center articles, reference, and conceptual documentation. Not for marketing copy or internal engineering plans unless explicitly requested.
---

# Diátaxis for customer documentation

Use the reader's need to choose the document's purpose, content, and form. This skill adapts [Diátaxis](https://diataxis.fr/) by Daniele Procida. The customer-specific checks below are local application guidance, not additional Diátaxis rules.

## Identify the need

Use the request and available product material to identify the audience, their starting knowledge, and their intended result. Ask only when a missing fact would materially change the document. For small edits, preserve the existing purpose unless it causes a clear problem.

Use the [Diátaxis compass](https://diataxis.fr/compass/) to distinguish the modes:

| Reader's need | Mode | Example customer request |
| --- | --- | --- |
| Learn through a guided activity | Tutorial | Help me create my first project with sample data. |
| Complete a real task using existing skills | How-to guide | Help me export this month's records. |
| Look up precise facts while working | Reference | Which export formats and fields are supported? |
| Understand concepts and reasons | Explanation | Why do exports differ from live reports? |

Classify by purpose, not by title or presence of numbered steps. A beginner can need a how-to guide; an experienced user can need a tutorial for an unfamiliar skill. A factual example can belong in reference without becoming a tutorial.

Choose a primary mode for each page or clearly bounded section. Where purposes compete, keep necessary context and link to the other material. Do not split a short useful passage merely to satisfy a category. If the user requests a single document, use distinct sections where needed rather than forcing separate files.

## Write for the chosen mode

### Tutorial

Create a guided exercise that builds skill through action. State what the reader will make or accomplish, and establish a reproducible starting point. Choose one concrete path with small steps. Give visible results early and include expected observations at useful checkpoints. Direct attention to what the reader should notice.

Keep explanations brief and defer alternatives to linked material. Prefer sample data and a safe practice environment. Include reset or cleanup instructions when the exercise needs them. Test the full sequence where feasible; a plausible list of commands is not evidence that the lesson works.

Source: [Tutorials](https://diataxis.fr/tutorials/).

### How-to guide

Address a specific customer goal or problem. Name that goal in the title. State relevant prerequisites, then give actions in a useful order. Include decision points and conditional paths when real situations require them. Assume the stated baseline competence, not knowledge of undocumented product behavior.

Keep enough detail to complete the task, but move extended teaching and option catalogs to links. Give a way to check the outcome. For troubleshooting, connect an observed symptom to checks and actions; do not present an unverified cause as certain.

Source: [How-to guides](https://diataxis.fr/how-to-guides/).

### Reference

Describe the product accurately and neutrally. Organize entries around its public concepts and interfaces, with consistent fields and terminology. Cover the declared scope completely rather than claiming to describe the whole product.

For the relevant interface, include supported values, defaults, units, constraints, permissions, outputs, errors, and version limits where established. Use short examples to illustrate exact behavior. Link to task instructions or background rather than embedding a lesson or argument in the entry.

Source: [Reference](https://diataxis.fr/reference/).

### Explanation

Answer a bounded conceptual question. Connect concepts and explain relevant context, reasons, constraints, and tradeoffs. Use examples or analogies when they help the reader understand relationships. Identify the limits of an analogy.

Discuss alternatives and perspectives when useful. Distinguish documented design intent from an inference; do not invent historical reasons from implementation alone. Link to procedures and specifications instead of turning the discussion into either.

Source: [Explanation](https://diataxis.fr/explanation/).

## Ground customer claims

Before writing product-specific details, inspect the supplied sources and relevant existing documentation. Verify claims against the applicable product version, public interface, schema, code, or observed behavior as available. Internal code alone may not establish customer access or released availability.

- Use exact visible UI labels and public API names. Keep internal implementation details out unless they help the customer act or understand.
- Establish relevant account roles, plan limits, region limits, and prerequisites from evidence. Do not invent them.
- Use clearly marked example values. Do not include credentials or private customer data.
- Place specific consequences, costs, or irreversible effects before the affected step when evidence shows they apply.
- Keep unresolved facts in author notes outside customer-ready prose. If a missing fact blocks accurate instructions, ask for it or identify the unfinished portion explicitly.

Follow the product's terminology and requested voice. Prefer direct language and meaningful titles. Do not add promotional claims to fill gaps.

## Improve existing documentation

Apply [Diátaxis workflow guidance](https://diataxis.fr/how-to-use-diataxis/) through small, useful changes. Start with the requested page or problem. Do not create empty categories, require all four modes for every feature, or restructure the whole site without need.

For reviews, identify the passage, the reader need it fails to serve, and a concrete correction. For requested reorganization, map existing content to reader needs, identify missing journeys and competing purposes, and preserve useful content and links. Use customer-friendly navigation labels; the four mode names are not mandatory menu titles.

## Check the result

Check purpose and factual accuracy separately. Confirm that the document serves its intended reader and that its product claims have support. For executable instructions, run the relevant sequence in an authorized environment when feasible. Check links and the existing documentation build when applicable. Report what was checked and any remaining gaps without claiming unperformed validation.

Deliver the requested document, edit, or review. Keep classification notes and source uncertainties out of the customer copy unless requested. This skill does not authorize publication or external account changes.
