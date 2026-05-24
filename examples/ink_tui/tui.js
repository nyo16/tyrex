// Example: Terminal UI rendering with ANSI escape codes
// Demonstrates rich terminal output from Tyrex — colored text, borders, progress bars

// ANSI color/style helpers
const ESC = "\x1b[";
const RESET = `${ESC}0m`;
const BOLD = `${ESC}1m`;
const DIM = `${ESC}2m`;
const UNDERLINE = `${ESC}4m`;

const fg = {
  red: (s) => `${ESC}31m${s}${RESET}`,
  green: (s) => `${ESC}32m${s}${RESET}`,
  yellow: (s) => `${ESC}33m${s}${RESET}`,
  blue: (s) => `${ESC}34m${s}${RESET}`,
  magenta: (s) => `${ESC}35m${s}${RESET}`,
  cyan: (s) => `${ESC}36m${s}${RESET}`,
  white: (s) => `${ESC}37m${s}${RESET}`,
  bold: (s) => `${BOLD}${s}${RESET}`,
  dim: (s) => `${DIM}${s}${RESET}`,
  underline: (s) => `${UNDERLINE}${s}${RESET}`,
};

// Box-drawing characters (rounded)
const box = { tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│" };

function drawBox(title, lines, width) {
  const w = width || Math.max(title.length + 4, ...lines.map((l) => stripAnsi(l).length + 4));
  const top = `${box.tl}${box.h} ${fg.bold(title)} ${box.h.repeat(Math.max(0, w - stripAnsi(title).length - 5))}${box.tr}`;
  const bottom = `${box.bl}${box.h.repeat(w - 2)}${box.br}`;
  const body = lines.map((l) => {
    const pad = w - 2 - stripAnsi(l).length;
    return `${box.v} ${l}${" ".repeat(Math.max(0, pad - 1))}${box.v}`;
  });
  return [top, ...body, bottom].join("\n");
}

function stripAnsi(s) {
  return s.replace(/\x1b\[[0-9;]*m/g, "");
}

// 1. Status Dashboard — bordered box with colored status indicators
globalThis.renderStatusDashboard = (data) => {
  const services = typeof data === "string" ? JSON.parse(data) : data;

  const statusStyle = (status) => {
    switch (status) {
      case "up":       return { icon: "●", color: fg.green, label: "UP" };
      case "degraded": return { icon: "●", color: fg.yellow, label: "DEGRADED" };
      case "down":     return { icon: "●", color: fg.red, label: "DOWN" };
      default:         return { icon: "○", color: fg.white, label: status.toUpperCase() };
    }
  };

  const lines = services.map((svc) => {
    const s = statusStyle(svc.status);
    return `${s.color(s.icon)} ${svc.name.padEnd(20)} ${s.color(fg.bold(s.label))}`;
  });

  return drawBox("Service Status", lines, 42);
};

// 2. Data table with bold headers and aligned columns
globalThis.renderDataTable = (data) => {
  const { headers, rows } = typeof data === "string" ? JSON.parse(data) : data;

  const colWidths = headers.map((hdr, i) => {
    const maxData = rows.reduce((max, row) => Math.max(max, String(row[i]).length), 0);
    return Math.max(hdr.length, maxData) + 2;
  });

  const headerLine = headers.map((h, i) => fg.cyan(fg.bold(h.padEnd(colWidths[i])))).join("");
  const separator = fg.dim(colWidths.map((w) => "─".repeat(w)).join(""));
  const bodyLines = rows.map((row) =>
    row.map((cell, i) => String(cell).padEnd(colWidths[i])).join("")
  );

  return [headerLine, separator, ...bodyLines].join("\n");
};

// 3. Progress bars — ASCII bar charts color-coded by progress
globalThis.renderProgressBars = (data) => {
  const tasks = typeof data === "string" ? JSON.parse(data) : data;
  const barWidth = 30;

  const barColor = (pct) => {
    if (pct < 33) return fg.red;
    if (pct < 67) return fg.yellow;
    return fg.green;
  };

  const title = fg.bold(fg.underline("Progress"));
  const lines = tasks.map((task) => {
    const filled = Math.round((task.progress / 100) * barWidth);
    const empty = barWidth - filled;
    const bar = "█".repeat(filled) + "░".repeat(empty);
    const color = barColor(task.progress);
    return `${task.name.padEnd(18)} ${color(bar)} ${fg.bold(String(task.progress).padStart(3))}%`;
  });

  return [title, ...lines].join("\n");
};

// 4. Combined system dashboard — composes all sections
globalThis.renderSystemDashboard = (data) => {
  const { services, table, tasks } = typeof data === "string" ? JSON.parse(data) : data;

  const statusSection = globalThis.renderStatusDashboard(services);
  const tableSection = globalThis.renderDataTable(table);
  const progressSection = globalThis.renderProgressBars(tasks);

  return [statusSection, "", tableSection, "", progressSection].join("\n");
};
