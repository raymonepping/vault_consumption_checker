// md_to_docx.mjs
import fs from "node:fs";
import MarkdownIt from "markdown-it";
import {
  Document,
  Packer,
  Paragraph,
  TextRun,
  HeadingLevel,
  Table,
  TableRow,
  TableCell,
  WidthType,
  BorderStyle,
  ShadingType,
  AlignmentType,
  VerticalAlign,
  LevelFormat,
  TableOfContents,
  PageBreak,
  Footer,
  PageNumber,
} from "docx";

const md = new MarkdownIt({ html: false });

// ---------------- document font setup ----------------
const FONT_BODY = "IBM Plex Sans";
const FONT_MONO = "Consolas";

const input = process.argv[2];
if (!input) {
  console.error("Usage: node md_to_docx.mjs <input.md> [output.docx]");
  process.exit(2);
}

const rawOut = process.argv[3];
const output = (rawOut || input.replace(/\.md$/i, ".docx")).replace(/\.doc$/i, ".docx");

const src = fs.readFileSync(input, "utf8");
const tokens = md.parse(src, {});

// ---------------- inline rendering ----------------
function runsFromInline(inlineTok, opts = {}) {
  const kids = inlineTok?.children || [];
  const runs = [];

  let bold = false;
  let italics = false;

  for (const t of kids) {
    switch (t.type) {
      case "text": {
        if (t.content) {
          runs.push(
            new TextRun({
              text: t.content,
              bold,
              italics,
              font: FONT_BODY,
            })
          );
        }
        break;
      }

      case "strong_open":
        bold = true;
        break;
      case "strong_close":
        bold = false;
        break;

      case "em_open":
        italics = true;
        break;
      case "em_close":
        italics = false;
        break;

      case "code_inline": {
        runs.push(
          new TextRun({
            text: t.content ?? "",
            font: FONT_MONO,
            bold,
            italics,
          })
        );
        break;
      }

      case "softbreak":
      case "hardbreak":
        runs.push(new TextRun({ break: 1 }));
        break;

      default:
        break;
    }
  }

  // Optional: bold header cells (your table calls can pass opts.forceBold)
  if (opts.forceBold) {
    return runs.map((r) => new TextRun({ ...r.options, bold: true }));
  }

  return runs.length ? runs : [new TextRun({ text: "", font: FONT_BODY })];
}

// ---------------- cell type detection ----------------
function isNumericCellText(s) {
  return /^\s*-?\d+(\.\d+)?\s*$/.test(String(s ?? ""));
}

// ---------------- block parsing helpers ----------------
function parseParagraph(tokens, i, bulletLevel = null) {
  const inlineTok = tokens[i + 1];
  const children = runsFromInline(inlineTok);

  const p =
    bulletLevel === null
      ? new Paragraph({ children })
      : new Paragraph({
          children,
          numbering: { reference: "sqBullet", level: bulletLevel },
        });

  return { node: p, next: i + 3 };
}

function parseHeading(tokens, i) {
  const tag = tokens[i].tag || "h4";
  const level = Number(String(tag).replace("h", "")) || 4;
  const text = tokens[i + 1]?.content ?? "";

  const map = {
    1: HeadingLevel.HEADING_1,
    2: HeadingLevel.HEADING_2,
    3: HeadingLevel.HEADING_3,
    4: HeadingLevel.HEADING_4,
  };

  const p = new Paragraph({
    text,
    heading: map[level] || HeadingLevel.HEADING_4,
  });

  return { node: p, next: i + 3 };
}

function parseFence(tokens, i) {
  const content = (tokens[i].content ?? "").replace(/\s+$/, "");
  const p = new Paragraph({
    children: [
      new TextRun({
        text: content,
        font: FONT_MONO,
      }),
    ],
  });
  return { node: p, next: i + 1 };
}

function parseList(tokens, i, level = 0) {
  const openType = tokens[i].type;
  const closeType = openType === "ordered_list_open" ? "ordered_list_close" : "bullet_list_close";

  const nodes = [];
  let idx = i + 1;

  while (idx < tokens.length && tokens[idx].type !== closeType) {
    if (tokens[idx].type === "list_item_open") {
      idx++;

      while (idx < tokens.length && tokens[idx].type !== "list_item_close") {
        if (tokens[idx].type === "paragraph_open") {
          const out = parseParagraph(tokens, idx, level);
          nodes.push(out.node);
          idx = out.next;
          continue;
        }

        if (tokens[idx].type === "bullet_list_open" || tokens[idx].type === "ordered_list_open") {
          const out = parseList(tokens, idx, level + 1);
          nodes.push(...out.nodes);
          idx = out.next;
          continue;
        }

        if (tokens[idx].type === "fence") {
          const out = parseFence(tokens, idx);
          nodes.push(out.node);
          idx = out.next;
          continue;
        }

        idx++;
      }

      idx++;
      continue;
    }

    idx++;
  }

  return { nodes, next: idx + 1 };
}

function parseTable(tokens, i) {
  const rows = [];
  let idx = i + 1;
  let inHeader = false;

  while (idx < tokens.length && tokens[idx].type !== "table_close") {
    const t = tokens[idx];

    if (t.type === "thead_open") inHeader = true;
    if (t.type === "thead_close") inHeader = false;

    if (t.type === "tr_open") {
      idx++;
      const cells = [];

      while (idx < tokens.length && tokens[idx].type !== "tr_close") {
        const cellTok = tokens[idx];

        if (cellTok.type === "th_open" || cellTok.type === "td_open") {
          const inlineTok = tokens[idx + 1];
          const cellText = inlineTok?.content ?? "";

          const cellRuns = runsFromInline(inlineTok, { forceBold: inHeader });

          const para = new Paragraph({
            children: cellRuns,
            alignment: inHeader
              ? AlignmentType.LEFT
              : isNumericCellText(cellText)
                ? AlignmentType.RIGHT
                : AlignmentType.LEFT,
          });

          const cell = new TableCell({
            verticalAlign: VerticalAlign.CENTER,
            shading: inHeader
              ? { type: ShadingType.CLEAR, fill: "F2F2F2", color: "auto" }
              : undefined,
            children: [para],
          });

          cells.push(cell);
          idx += 3;
          continue;
        }

        idx++;
      }

      rows.push(new TableRow({ children: cells }));
      idx++;
      continue;
    }

    idx++;
  }

  const table = new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    borders: {
      top: { style: BorderStyle.SINGLE, size: 1, color: "BFBFBF" },
      bottom: { style: BorderStyle.SINGLE, size: 1, color: "BFBFBF" },
      left: { style: BorderStyle.SINGLE, size: 1, color: "BFBFBF" },
      right: { style: BorderStyle.SINGLE, size: 1, color: "BFBFBF" },
      insideHorizontal: { style: BorderStyle.SINGLE, size: 1, color: "BFBFBF" },
      insideVertical: { style: BorderStyle.SINGLE, size: 1, color: "BFBFBF" },
    },
    rows,
  });

  return { node: table, next: idx + 1 };
}

// ---------------- main block walker ----------------
const children = [];
let tocInserted = false;

let i = 0;

let needsSpacerBeforeNextHeading = false;

while (i < tokens.length) {
  const t = tokens[i];

  if (t.type === "heading_open") {
    const headingText = tokens[i + 1]?.content ?? "";

    if (headingText === "Top namespaces by clients") {
      children.push(new Paragraph({ children: [new PageBreak()] }));
      needsSpacerBeforeNextHeading = false;
    }

    if (headingText === "Monthly checks") {
      children.push(new Paragraph({ children: [new PageBreak()] }));
      needsSpacerBeforeNextHeading = false;
    }

    if (needsSpacerBeforeNextHeading) {
      children.push(new Paragraph({ text: "" }));
      needsSpacerBeforeNextHeading = false;
    }

    const out = parseHeading(tokens, i);
    children.push(out.node);

    // Insert TOC after the first H1 only
    const level = Number(String(tokens[i].tag || "h4").replace("h", "")) || 4;
    if (!tocInserted && level === 1) {
      tocInserted = true;

      children.push(new Paragraph({ text: "" }));

      // TOC title (not a heading, so it won't appear inside the TOC)
      children.push(
        new Paragraph({
          children: [new TextRun({ text: "Table of Contents", bold: true, font: FONT_BODY })],
        })
      );

      children.push(
        new TableOfContents("Table of Contents", {
          hyperlink: true,
          headingStyleRange: "1-3", // include H1-H3
        })
      );

      // Start content on a new page after the TOC
      children.push(new Paragraph({ children: [new PageBreak()] }));
    }

    i = out.next;
    continue;
  }

  if (t.type === "paragraph_open") {
    const out = parseParagraph(tokens, i, null);
    children.push(out.node);
    needsSpacerBeforeNextHeading = false;
    i = out.next;
    continue;
  }

  if (t.type === "bullet_list_open" || t.type === "ordered_list_open") {
    const out = parseList(tokens, i, 0);
    children.push(...out.nodes);
    needsSpacerBeforeNextHeading = true; // <-- next heading gets a blank line
    i = out.next;
    continue;
  }

  if (t.type === "table_open") {
    const out = parseTable(tokens, i);
    children.push(out.node);
    needsSpacerBeforeNextHeading = true; // <-- next heading gets a blank line
    i = out.next;
    continue;
  }

  if (t.type === "fence") {
    const out = parseFence(tokens, i);
    children.push(out.node);
    needsSpacerBeforeNextHeading = false;
    i = out.next;
    continue;
  }

  i++;
}

const footerFirst = new Footer({
  children: [new Paragraph("")], // no page number on page 1
});

const footerDefault = new Footer({
  children: [
    new Paragraph({
      alignment: AlignmentType.RIGHT,
      children: [
        new TextRun({
          font: FONT_BODY,
          children: ["Page ", PageNumber.CURRENT, " of ", PageNumber.TOTAL_PAGES],
        }),
      ],
    }),
  ],
});

const doc = new Document({
  features: {
    updateFields: true, // <-- key line
  },
  numbering: {
    config: [
      {
        reference: "sqBullet",
        levels: [
          {
            level: 0,
            format: LevelFormat.BULLET,
            text: "▪", // small square (U+25AA). Try "■" if you want bigger.
            alignment: AlignmentType.LEFT,
            style: {
              paragraph: { indent: { left: 720, hanging: 360 } }, // tweak if needed
              run: { font: FONT_BODY, size: 22 },
            },
          },
          {
            level: 1,
            format: LevelFormat.BULLET,
            text: "▪",
            alignment: AlignmentType.LEFT,
            style: {
              paragraph: { indent: { left: 1080, hanging: 360 } },
              run: { font: FONT_BODY, size: 22 },
            },
          },
          {
            level: 2,
            format: LevelFormat.BULLET,
            text: "▪",
            alignment: AlignmentType.LEFT,
            style: {
              paragraph: { indent: { left: 1440, hanging: 360 } },
              run: { font: FONT_BODY, size: 22 },
            },
          },
        ],
      },
    ],
  },
  styles: {
    default: {
      document: {
        run: {
          font: FONT_BODY,
          size: 22,
        },
        paragraph: {
          spacing: { line: 276, after: 120 },
        },
      },
    },
    paragraphStyles: [
      {
        id: "Heading1",
        name: "Heading 1",
        basedOn: "Normal",
        next: "Normal",
        quickFormat: true,
        run: { font: FONT_BODY, bold: true, size: 36 }, // 18pt
        paragraph: { spacing: { before: 240, after: 160 } },
      },
      {
        id: "Heading2",
        name: "Heading 2",
        basedOn: "Normal",
        next: "Normal",
        quickFormat: true,
        run: { font: FONT_BODY, bold: true, size: 28 }, // 14pt
        paragraph: { spacing: { before: 200, after: 120 } },
      },
      {
        id: "Heading3",
        name: "Heading 3",
        basedOn: "Normal",
        next: "Normal",
        quickFormat: true,
        run: { font: FONT_BODY, bold: true, size: 24 }, // 12pt
        paragraph: { spacing: { before: 160, after: 100 } },
      },
    ],
  },
  sections: [
    {
      properties: {
        titlePage: true, // separate first page
        page: {
          pageNumbers: {
            start: 1, // so page 2 shows "2"
          },
        },
      },
      footers: {
        first: footerFirst,
        default: footerDefault,
      },
      children,
    },
  ],
});

const buf = await Packer.toBuffer(doc);
fs.writeFileSync(output, buf);
console.log(`Wrote: ${output}`);
