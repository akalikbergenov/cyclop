// Кнопка «Скачать» ведёт прямо на .dmg последнего релиза, а не на страницу
// релизов GitHub. Ссылка, номер и размер берутся при сборке из GitHub API;
// без сети остаётся то, что лежит в src/data/release.json с прошлой сборки.
//
// Если у релиза есть копия образа под постоянным именем Cyclop.dmg, ссылка
// ведёт на releases/latest/download/Cyclop.dmg — она не устаревает между
// выпуском и пересборкой сайта.
import { readFile, writeFile } from "node:fs/promises";

const repo = "akalikbergenov/cyclop";
const dataFile = new URL("../src/data/release.json", import.meta.url);
const redirects = new URL("../public/_redirects", import.meta.url);

let info = JSON.parse(await readFile(dataFile, "utf8"));
try {
  const res = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "cyclopnotch.app build" },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}`);
  const release = await res.json();
  const stable = release.assets.find((a) => a.name === "Cyclop.dmg");
  const versioned = release.assets.find((a) => /^Cyclop-[\d.]+\.dmg$/.test(a.name));
  const asset = stable ?? versioned;
  if (!asset) throw new Error("в релизе нет .dmg");
  info = {
    version: release.tag_name.replace(/^v/, ""),
    url: stable
      ? `https://github.com/${repo}/releases/latest/download/Cyclop.dmg`
      : asset.browser_download_url,
    sizeMB: Math.round((asset.size / 1048576) * 10) / 10,
    published: release.published_at.slice(0, 10),
    notes: release.html_url,
  };
  await writeFile(dataFile, JSON.stringify(info, null, 2) + "\n");
  console.log(`release-info: ${info.version}, ${info.url}`);
} catch (error) {
  console.warn(`release-info: ${error.message}; остаётся ${info.version}`);
}

await writeFile(
  redirects,
  `/download ${info.url} 302\n/download/ ${info.url} 302\n/github https://github.com/${repo} 302\n`,
);
