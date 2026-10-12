"use strict";
(() => {
  const dialog = document.getElementById("calendarDialog"),
    grid = document.getElementById("calendarGrid"),
    heading = document.getElementById("calendarHeading");
  let target = null,
    year = 2026,
    month = 0,
    mode = "day";
  const pad = (n) => String(n).padStart(2, "0"),
    dateString = (y, m, d) => `${y}-${pad(m + 1)}-${pad(d)}`;
  function render() {
    grid.replaceChildren();
    grid.className = "calendar-grid " + mode;
    heading.textContent =
      mode === "year"
        ? `${Math.floor(year / 12) * 12}–${Math.floor(year / 12) * 12 + 11}`
        : mode === "month"
          ? `${year}年`
          : `${year}年 ${month + 1}月`;
    heading.setAttribute(
      "aria-label",
      mode === "day" ? "选择月份" : mode === "month" ? "选择年份" : "返回日期",
    );
    function add(label, action, options = {}) {
      const b = document.createElement("button");
      b.textContent = label;
      b.disabled = !!options.disabled;
      b.className = options.className || "";
      b.onclick = action;
      grid.append(b);
      return b;
    }
    if (mode === "year") {
      const start = Math.floor(year / 12) * 12;
      for (let i = start; i < start + 12; i++)
        add(
          i + "",
          () => {
            year = i;
            mode = "month";
            render();
          },
          { disabled: i < 1970 || i > 9999 },
        );
    } else if (mode === "month") {
      for (let i = 0; i < 12; i++)
        add(i + 1 + "月", () => {
          month = i;
          mode = "day";
          render();
        });
    } else {
      for (const name of ["一", "二", "三", "四", "五", "六", "日"]) {
        const s = document.createElement("span");
        s.textContent = name;
        grid.append(s);
      }
      const offset = (new Date(Date.UTC(year, month, 1)).getUTCDay() + 6) % 7;
      for (let i = 0; i < 42; i++) {
        const d = new Date(Date.UTC(year, month, 1 - offset + i)),
          y = d.getUTCFullYear(),
          m = d.getUTCMonth(),
          day = d.getUTCDate(),
          value = dateString(y, m, day);
        const b = add(
          day,
          () => {
            target.value = value;
            document.getElementById(target.id + "Enabled").checked = true;
            target.dispatchEvent(new Event("input"));
            dialog.close();
          },
          {
            disabled: y < 1970 || y > 9999,
            className:
              (m !== month ? "outside " : "") +
              (value === target.value ? "chosen" : ""),
          },
        );
        b.setAttribute("aria-label", value);
      }
    }
  }
  document.querySelectorAll("[data-calendar]").forEach(
    (button) =>
      (button.onclick = () => {
        target = document.getElementById(button.dataset.calendar);
        const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(target.value);
        const now = new Date();
        year = match ? +match[1] : now.getFullYear();
        month = match ? +match[2] - 1 : now.getMonth();
        mode = "day";
        render();
        dialog.showModal();
      }),
  );
  heading.onclick = () => {
    mode = mode === "day" ? "month" : mode === "month" ? "year" : "day";
    render();
  };
  for (const [id, step] of [
    ["calendarPrev", -1],
    ["calendarNext", 1],
  ])
    document.getElementById(id).onclick = () => {
      if (mode === "year") year += step * 12;
      else if (mode === "month") year += step;
      else {
        month += step;
        if (month < 0) {
          month = 11;
          year--;
        }
        if (month > 11) {
          month = 0;
          year++;
        }
      }
      year = Math.max(1970, Math.min(9999, year));
      render();
    };
  document.getElementById("calendarClose").onclick = () => dialog.close();
  document.getElementById("calendarToday").onclick = () => {
    const value = new Intl.DateTimeFormat("sv-SE", {
      timeZone: "Asia/Shanghai",
    }).format(new Date());
    target.value = value;
    document.getElementById(target.id + "Enabled").checked = true;
    target.dispatchEvent(new Event("input"));
    dialog.close();
  };
})();
