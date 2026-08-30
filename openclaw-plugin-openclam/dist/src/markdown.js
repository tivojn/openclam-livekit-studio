const MARKDOWN_LINK_OPEN = /!?\[([^\]\r\n]*)\]\(/gu;
function isEscaped(text, index) {
    let slashes = 0;
    for (let cursor = index - 1; cursor >= 0 && text[cursor] === "\\"; cursor -= 1) {
        slashes += 1;
    }
    return slashes % 2 === 1;
}
function markdownLinkEnd(text, destinationStart) {
    let depth = 1;
    let angleDestination = false;
    let sawDestinationCharacter = false;
    for (let cursor = destinationStart; cursor < text.length; cursor += 1) {
        const character = text[cursor] ?? "";
        if (character === "\r" || character === "\n")
            return undefined;
        if (character === "\\") {
            cursor += 1;
            sawDestinationCharacter = true;
            continue;
        }
        if (!sawDestinationCharacter && /\s/u.test(character))
            continue;
        if (!sawDestinationCharacter) {
            sawDestinationCharacter = true;
            angleDestination = character === "<";
        }
        if (angleDestination) {
            if (character === ">")
                angleDestination = false;
            continue;
        }
        if (character === "(") {
            depth += 1;
            continue;
        }
        if (character !== ")")
            continue;
        depth -= 1;
        if (depth === 0)
            return cursor + 1;
    }
    return undefined;
}
export function rewriteMarkdownLinks(text, rewrite) {
    let output = "";
    let copiedThrough = 0;
    MARKDOWN_LINK_OPEN.lastIndex = 0;
    let match;
    while ((match = MARKDOWN_LINK_OPEN.exec(text)) !== null) {
        if (isEscaped(text, match.index))
            continue;
        const destinationStart = MARKDOWN_LINK_OPEN.lastIndex;
        const end = markdownLinkEnd(text, destinationStart);
        if (end === undefined)
            continue;
        const raw = text.slice(match.index, end);
        const replacement = rewrite({
            raw,
            label: match[1] ?? "",
            destination: text.slice(destinationStart, end - 1),
            image: raw.startsWith("!"),
        });
        if (replacement !== undefined) {
            output += text.slice(copiedThrough, match.index);
            output += replacement;
            copiedThrough = end;
        }
        MARKDOWN_LINK_OPEN.lastIndex = end;
    }
    return `${output}${text.slice(copiedThrough)}`;
}
