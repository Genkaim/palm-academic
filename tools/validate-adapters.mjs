import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const assetsRoot = join(repositoryRoot, "app", "src", "main", "assets");
const indexPath = join(assetsRoot, "schools", "index.json");
const errors = [];
const warnings = [];
const referencedDefinitions = new Set();
const referencedAdapters = new Set();

function reportError(scope, message) {
  errors.push(`${scope}: ${message}`);
}

function requireValue(condition, scope, message) {
  if (!condition) reportError(scope, message);
  return condition;
}

function readJson(path, scope) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    reportError(scope, `JSON 解析失败：${error.message}`);
    return null;
  }
}

function isSafeAssetPath(value, prefix, suffix) {
  return typeof value === "string" &&
    value.startsWith(prefix) && value.endsWith(suffix) &&
    !value.includes("..") && /^[A-Za-z0-9._/-]+$/.test(value);
}

function isHttpsUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

function minutes(value) {
  const match = /^(?:[01]\d|2[0-3]):[0-5]\d$/.exec(value);
  return match ? Number(value.slice(0, 2)) * 60 + Number(value.slice(3)) : null;
}

function validateScheduleProfiles(school, scope) {
  const profiles = school.readerConfig?.scheduleProfiles;
  if (!requireValue(Array.isArray(profiles) && profiles.length > 0, scope,
    "readerConfig.scheduleProfiles 不能为空")) return;

  requireValue(profiles.some((profile) => profile?.locationPattern === ""), scope,
    "必须包含 locationPattern 为空字符串的默认作息 profile");

  profiles.forEach((profile, profileIndex) => {
    const profileScope = `${scope}.scheduleProfiles[${profileIndex}]`;
    requireValue(typeof profile?.locationPattern === "string", profileScope,
      "locationPattern 必须是字符串");
    if (typeof profile?.locationPattern === "string") {
      try { new RegExp(profile.locationPattern); } catch (error) {
        reportError(profileScope, `locationPattern 不是有效正则：${error.message}`);
      }
    }
    const unitTimes = profile?.unitTimes;
    if (!requireValue(unitTimes && typeof unitTimes === "object" &&
      !Array.isArray(unitTimes) && Object.keys(unitTimes).length > 0,
    profileScope, "unitTimes 不能为空")) return;

    for (const [section, range] of Object.entries(unitTimes)) {
      const rangeScope = `${profileScope}.unitTimes.${section}`;
      requireValue(/^[1-9]\d*$/.test(section), rangeScope, "节次必须是正整数字符串");
      if (!requireValue(Array.isArray(range) && range.length === 2, rangeScope,
        "时间必须是 [开始, 结束]")) continue;
      const start = minutes(range[0]);
      const end = minutes(range[1]);
      requireValue(start !== null && end !== null, rangeScope, "时间必须使用 HH:mm 24 小时制");
      if (start !== null && end !== null) {
        requireValue(start < end, rangeScope, "结束时间必须晚于开始时间");
      }
    }
  });
}

function validateDefinition(assetPath) {
  const absolutePath = join(assetsRoot, assetPath);
  const definition = readJson(absolutePath, assetPath);
  if (!definition) return;

  requireValue(definition.schemaVersion === 1, assetPath, "schemaVersion 必须为 1");
  requireValue(typeof definition.id === "string" && /^[a-z0-9-]+$/.test(definition.id),
    assetPath, "id 只能包含小写字母、数字和连字符");
  requireValue(typeof definition.name === "string" && definition.name.trim(),
    assetPath, "name 不能为空");
  requireValue(typeof definition.author?.name === "string" && definition.author.name.trim(),
    assetPath, "author.name 不能为空");
  requireValue(typeof definition.author?.email === "string" &&
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(definition.author.email),
  assetPath, "author.email 缺失或格式无效");
  requireValue(isHttpsUrl(definition.baseUrl), assetPath, "baseUrl 必须是无凭据的 HTTPS 地址");
  requireValue(Array.isArray(definition.groups), assetPath, "groups 必须是数组");

  if (Array.isArray(definition.groups)) {
    definition.groups.forEach((group, groupIndex) => {
      const groupScope = `${assetPath}.groups[${groupIndex}]`;
      requireValue(typeof group?.title === "string" && group.title.trim(), groupScope, "title 不能为空");
      requireValue(Array.isArray(group?.items), groupScope, "items 必须是数组");
      group?.items?.forEach((item, itemIndex) => {
        const itemScope = `${groupScope}.items[${itemIndex}]`;
        requireValue(typeof item?.title === "string" && item.title.trim(), itemScope, "title 不能为空");
        requireValue(typeof item?.path === "string" &&
          (item.path.startsWith("/") || isHttpsUrl(item.path)), itemScope,
        "path 必须是站内绝对路径或 HTTPS 地址");
        requireValue(item.quick === undefined || typeof item.quick === "boolean", itemScope,
          "quick 必须是布尔值");
      });
    });
  }

  const adapterPath = definition.readerAdapter;
  if (!requireValue(isSafeAssetPath(adapterPath, "adapters/", ".js"), assetPath,
    "readerAdapter 路径无效")) return;
  referencedAdapters.add(adapterPath);
  const absoluteAdapterPath = join(assetsRoot, adapterPath);
  if (!requireValue(existsSync(absoluteAdapterPath), assetPath, `找不到 ${adapterPath}`)) return;
  try {
    execFileSync(process.execPath, ["--check", absoluteAdapterPath], { stdio: "pipe" });
  } catch (error) {
    reportError(adapterPath, `JavaScript 语法检查失败\n${error.stderr?.toString().trim() || error.message}`);
  }
  const script = readFileSync(absoluteAdapterPath, "utf8");
  requireValue(script.includes("PalmAcademicAdapter"), adapterPath,
    "必须暴露 PalmAcademicAdapter");
  requireValue(script.includes("PalmAcademicHost"), adapterPath,
    "必须通过 PalmAcademicHost 与 App 通信");
}

const index = readJson(indexPath, "schools/index.json");
if (index) {
  requireValue(index.schemaVersion === 1, "schools/index.json", "schemaVersion 必须为 1");
  requireValue(Number.isInteger(index.configVersion) && index.configVersion > 0,
    "schools/index.json", "configVersion 必须是正整数");
  if (requireValue(Array.isArray(index.schools) && index.schools.length > 0,
    "schools/index.json", "schools 不能为空")) {
    const ids = new Set();
    index.schools.forEach((school, schoolIndex) => {
      const scope = `schools/index.json.schools[${schoolIndex}]`;
      requireValue(typeof school?.id === "string" && /^[a-z0-9-]+$/.test(school.id),
        scope, "id 只能包含小写字母、数字和连字符");
      requireValue(!ids.has(school.id), scope, `学校 id 重复：${school.id}`);
      ids.add(school.id);
      requireValue(typeof school?.name === "string" && school.name.trim(), scope, "name 不能为空");
      requireValue(isHttpsUrl(school?.origin), scope, "origin 必须是无凭据的 HTTPS 地址");
      const definitionPath = school?.definitionAsset;
      if (requireValue(isSafeAssetPath(definitionPath, "schools/", ".json"), scope,
        "definitionAsset 路径无效")) {
        referencedDefinitions.add(definitionPath);
        requireValue(existsSync(join(assetsRoot, definitionPath)), scope, `找不到 ${definitionPath}`);
      }
      validateScheduleProfiles(school, scope);
    });
  }
}

for (const definitionPath of referencedDefinitions) validateDefinition(definitionPath);

for (const file of readdirSync(join(assetsRoot, "schools"))) {
  const assetPath = `schools/${file}`;
  if (file !== "index.json" && file.endsWith(".json") && !referencedDefinitions.has(assetPath)) {
    warnings.push(`${assetPath}: 文件未被 index.json 引用`);
  }
}
for (const file of readdirSync(join(assetsRoot, "adapters"))) {
  const assetPath = `adapters/${file}`;
  if (file.endsWith(".js") && !referencedAdapters.has(assetPath)) {
    warnings.push(`${assetPath}: 文件未被任何学校定义引用`);
  }
}

warnings.forEach((warning) => console.warn(`警告：${warning}`));
if (errors.length) {
  console.error(`适配校验失败（${errors.length} 项）：`);
  errors.forEach((error) => console.error(`- ${error}`));
  process.exit(1);
}

console.log(`适配校验通过：${index?.schools?.length ?? 0} 所学校，` +
  `${referencedDefinitions.size} 个定义，${referencedAdapters.size} 个适配器。`);
