import assert from "node:assert/strict";
import test from "node:test";
import {
  FORBIDDEN_TRANSLATION_RULES,
  mandatoryTerminologyFor,
  translationPolicyDigest,
  translationSystemPrompt,
} from "../scripts/translation-policy.mjs";
import {
  normalizeTranslationTerminology as normalizeTranslationTerminologyForPath,
  validateTranslationQuality as validateTranslationQualityForPath,
} from "../scripts/translation-quality.mjs";

const defaultRelativePath = "developer-guide.md";
const terminologyScopePaths = [
  defaultRelativePath,
  "mobile-device-development.md",
  "backend-deployment.md",
  "account-authentication.md",
  "adr/0002-drift-local-database.md",
  "adr/0003-stateful-shell-routing.md",
];

function validateTranslationQuality(sourceMarkdown, translatedMarkdown, label = "fixture", relativePath = defaultRelativePath) {
  return validateTranslationQualityForPath(sourceMarkdown, translatedMarkdown, relativePath, label);
}

function normalizeTranslationTerminology(sourceMarkdown, translatedMarkdown, label = "fixture", relativePath = defaultRelativePath) {
  return normalizeTranslationTerminologyForPath(sourceMarkdown, translatedMarkdown, relativePath, label);
}

const source = `# Deployment

Pakperk uses Rust, Flutter, OIDC, Keycloak, PostgreSQL, Kubernetes, Helm, and OpenTelemetry. The protected deployment workflow must verify the exact immutable candidate before exposing any production credential.

\`OpenAPI artifact\`

~~~text
/no_think
OpenAPI 艺术品
The protected deployment workflow must remain unchanged inside this example.
~~~
`;

test("accepts professional Chinese prose and preserved technical English names", () => {
  const translation = `# 部署

Pakperk 使用 Rust、Flutter、OIDC、Keycloak、PostgreSQL、Kubernetes、Helm 和 OpenTelemetry。受保护的部署工作流必须先验证完全一致且不可变的候选版本，才能公开任何生产凭证。

\`OpenAPI artifact\`

~~~text
/no_think
OpenAPI 艺术品
The protected deployment workflow must remain unchanged inside this example.
~~~
`;
  assert.doesNotThrow(() => validateTranslationQuality(source, translation, "fixture"));
});

test("rejects model-control leakage in prose but ignores it inside code", () => {
  assert.throws(
    () => validateTranslationQuality("This is prose.", "翻译结果如下：/no_think\n这是正文。", "fixture"),
    /fixture: model-control token leaked into prose: "\/no_think"/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "The example uses `/no_think`.",
    "该示例使用 `/no_think`。",
    "fixture",
  ));
});

test("rejects invented translator commentary", () => {
  assert.throws(
    () => validateTranslationQuality(
      "Preflight is allowed.",
      "预检已允许。\n\n（注：原文未提供完整内容，根据上下文推测。）",
      "fixture",
    ),
    /translator commentary was added/,
  );
});

test("enforces every centralized mandatory terminology rule", () => {
  const mandatoryRules = [...new Set(terminologyScopePaths.flatMap(mandatoryTerminologyFor))];
  for (const rule of mandatoryRules) {
    const relativePath = terminologyScopePaths.find((candidate) =>
      mandatoryTerminologyFor(candidate).includes(rule));
    assert.ok(relativePath, `no scope path covers ${rule.id}`);
    assert.doesNotThrow(
      () => validateTranslationQuality(rule.sourceExample, rule.validExample, `valid ${rule.id}`, relativePath),
      rule.id,
    );
    assert.throws(
      () => validateTranslationQuality(
        rule.sourceExample,
        "这是错误的翻译。",
        `invalid ${rule.id}`,
        relativePath,
      ),
      /required terminology|technical name|Pakperk UI label|obligation strength/,
      rule.id,
    );
  }
});

test("rejects every centralized high-confidence forbidden form", () => {
  for (const rule of FORBIDDEN_TRANSLATION_RULES) {
    assert.throws(
      () => validateTranslationQuality(rule.sourceExample, rule.invalidExample, "fixture"),
      /fixture: known bad calque/,
      rule.description,
    );
  }
  assert.doesNotThrow(() => validateTranslationQuality(
    "The example contains `OpenAPI artwork`.",
    "该示例包含 `OpenAPI 艺术品`。",
    "fixture",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "The gallery displays artwork.",
    "画廊展示艺术品。",
    "fixture",
  ));
});

test("rejects short unchanged English headings and list items but permits technical names", () => {
  assert.throws(
    () => validateTranslationQuality("# Protected rollout", "# Protected rollout", "fixture"),
    /short English prose copied unchanged/,
  );
  assert.throws(
    () => validateTranslationQuality("- Verify the signed candidate", "- Verify the signed candidate", "fixture"),
    /short English prose copied unchanged/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "# Rust and Flutter\n\n- GROBID\n- Ingress",
    "# Rust 和 Flutter\n\n- GROBID\n- Ingress",
    "fixture",
  ));
});

test("rejects detectable omissions within one prose block", () => {
  assert.throws(
    () => validateTranslationQuality(
      "Verify the signed candidate. Record the immutable digest.",
      "验证已签名的候选版本。",
      "fixture",
    ),
    /sentence\/clause markers decreased/,
  );
});

test("preserves obligation strength", () => {
  assert.throws(
    () => validateTranslationQuality(
      "The client must not publish stale data.",
      "客户端不应发布过期数据。",
      "fixture",
    ),
    /obligation strength for must not was not preserved/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "The client must not publish stale data.",
    "客户端不得发布过期数据。",
    "fixture",
  ));

  for (const sourceText of [
    "The client must never publish stale data.",
    "The client MUST NEVER publish stale data.",
  ]) {
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      "客户端绝不能发布过期数据。",
      "must-never fixture",
    ));
    for (const weakenedTranslation of [
      "客户端不应发布过期数据。",
      "客户端必须发布过期数据。",
    ]) {
      assert.throws(
        () => validateTranslationQuality(
          sourceText,
          weakenedTranslation,
          "must-never fixture",
        ),
        /obligation strength for must never was not preserved/,
      );
    }
  }

  assert.doesNotThrow(() => validateTranslationQuality(
    "The client must publish current data.",
    "客户端必须发布当前数据。",
    "positive-must fixture",
  ));
});

test("coverage diagnostics include compact, control-free source and translation excerpts", () => {
  const longEnglishWords = ["extraordinary", "instructional", "documentation", "diagnostic"]
    .map((word) => `${word}${"x".repeat(55)}`)
    .join(" \u0000 ");
  const longSource = [
    "First, the operator reviews all relevant evidence and records a complete decision for later inspection.",
    "Second, the reviewer compares every expected result against the supplied material and notes each discrepancy.",
    "Third, the team confirms that every prerequisite remains satisfied before continuing with the procedure.",
    "Fourth, the responsible engineer documents the observed behavior and explains the resulting conclusion.",
    "Finally, the reviewer records the completed analysis and communicates the outcome to the responsible team.",
  ].join("\n");
  const longTranslation = [
    "第一，操作人员检查所有相关证据，并记录完整决定以供后续核查。",
    "第二，审核人员将每项预期结果与所提供的材料进行比较，并注明所有差异。",
    "第三，团队确认所有前置条件仍然满足，然后再继续执行相应流程。",
    "第四，负责的工程师记录观察到的行为，并清楚说明由此得出的结论与后续处理依据。",
  ].join("\n");
  const insufficientSource = Array.from(
    { length: 20 },
    (_, index) => `descriptiveword${String.fromCharCode(97 + index)}`,
  ).join(" ");
  const cases = [
    {
      source: longEnglishWords,
      translation: longEnglishWords,
      pattern: /short English prose copied unchanged/,
      expectsTruncation: true,
    },
    {
      source: longSource,
      translation: longTranslation,
      pattern: /sentence\/clause markers decreased/,
      expectsTruncation: true,
    },
    {
      source: insufficientSource,
      translation: "已处理",
      pattern: /is too short to cover its source/,
      expectsTruncation: false,
    },
    {
      source: "The client must not publish stale data.",
      translation: "客户端不应发布过期数据。",
      pattern: /obligation strength for must not was not preserved/,
      expectsTruncation: false,
    },
  ];

  for (const testCase of cases) {
    assert.throws(
      () => validateTranslationQuality(
        testCase.source,
        testCase.translation,
        "diagnostic fixture",
      ),
      (error) => {
        assert.match(error.message, testCase.pattern);
        assert.match(error.message, /; source: ".+"; translation: ".+"$/u);
        assert.equal([...error.message].some((character) => {
          const codePoint = character.codePointAt(0);
          return codePoint < 32 || codePoint === 127;
        }), false);
        if (testCase.expectsTruncation) assert.match(error.message, /…/u);
        return true;
      },
    );
  }
});

test("accepts explicit fail-closed rejection without accepting omission or softening", () => {
  const sourceText =
    "Verification fails closed when required validation metadata is unavailable; unsigned tokens and token-selected algorithms are never accepted.";
  const exactTranslation =
    "当所需验证元数据不可用时，验证会失败并拒绝；未签名令牌和令牌选择的算法永远不会被接受。";
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    exactTranslation,
    "ADR fail-closed rejection",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));

  for (const accepted of [
    "门禁在失败时默认拒绝操作。",
    "门禁在故障时即拒绝操作。",
    "门禁失败则拒绝操作。",
    "门禁失败并拒绝操作。",
  ]) {
    assert.doesNotThrow(() => validateTranslationQuality(
      "The gate fails closed.",
      accepted,
      "professional fail-closed equivalent",
      "adr/0001-oidc-and-keycloak-reference.md",
    ));
  }

  const legacySource =
    "Genuine unscoped v1 derived/chat blobs fail closed instead of borrowing newer provenance.";
  for (const literalFailure of ["失败时会关闭", "失败时关闭", "会失败关闭"]) {
    const literalTranslation =
      `真正没有作用域的 v1 派生/聊天 blob ${literalFailure}，而不是借用较新的来源信息。`;
    const normalized = normalizeTranslationTerminology(
      legacySource,
      literalTranslation,
      "legacy importer fail-closed",
      "adr/0002-drift-local-database.md",
    );
    assert.equal(
      normalized,
      "真正没有作用域的 v1 派生/聊天 blob 失败时默认拒绝，而不是借用较新的来源信息。",
    );
    assert.doesNotThrow(() => validateTranslationQuality(
      legacySource,
      normalized,
      "legacy importer fail-closed",
      "adr/0002-drift-local-database.md",
    ));
  }

  const explicitLegacyTranslation =
    "真实的无范围 v1 派生/聊天二进制数据在失败时明确拒绝，而不是借用更新的溯源信息。";
  assert.equal(
    normalizeTranslationTerminology(
      legacySource,
      explicitLegacyTranslation,
      "explicit legacy importer rejection",
      "adr/0002-drift-local-database.md",
    ),
    explicitLegacyTranslation,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    legacySource,
    explicitLegacyTranslation,
    "explicit legacy importer rejection",
    "adr/0002-drift-local-database.md",
  ));

  const windowSource = "The window fails to close after rendering.";
  const windowTranslation = "窗口在渲染后关闭失败。";
  assert.equal(
    normalizeTranslationTerminology(
      windowSource,
      windowTranslation,
      "unrelated window close",
      "adr/0002-drift-local-database.md",
    ),
    windowTranslation,
  );

  assert.doesNotThrow(() => validateTranslationQuality(
    "The verifier fails closed when metadata is unavailable.",
    "元数据不可用时，验证器拒绝请求。",
    "source-conditioned unavailable rejection",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));

  const rejectedCases = [
    [sourceText, "当所需验证元数据不可用时，验证会停止处理；未签名令牌永远不会被接受。"],
    [sourceText, "当所需验证元数据不可用时，验证器可能拒绝请求；未签名令牌永远不会被接受。"],
    ["The verifier fails closed on malformed input.", "输入格式错误时，验证器拒绝请求。"],
    ["The verifier fails closed.", "验证器会安全失败。"],
    ["The verifier fails closed.", "验证器会失败关闭。"],
    ["The verifier fails closed.", "验证器关闭失败。"],
    ["The verifier fails closed.", "验证器在失败时可能拒绝。"],
    ["The verifier fails closed.", "验证器在失败时或许拒绝。"],
    ["The verifier fails closed.", "验证器在失败时未必拒绝。"],
    ["The verifier fails closed.", "验证器停止处理。"],
  ];
  for (const [rejectedSource, rejectedTranslation] of rejectedCases) {
    assert.throws(
      () => validateTranslationQuality(
        rejectedSource,
        rejectedTranslation,
        "invalid fail-closed translation",
        "adr/0001-oidc-and-keycloak-reference.md",
      ),
      /required terminology|known bad calque/,
    );
  }
});

test("preserves exact unambiguous names and product labels by count", () => {
  assert.throws(
    () => validateTranslationQuality(
      "GROBID validates GROBID output through Ingress. To Read opens To Read.",
      "GROBID 通过入口验证输出。To Read 会打开。",
      "fixture",
    ),
    /technical name "GROBID" count decreased \(2 -> 1\)/,
  );
  assert.throws(
    () => validateTranslationQuality(
      "WAL remains enabled. SQLCipher remains deferred.",
      "WAL 保持启用。数据库加密仍然延期。",
      "fixture",
    ),
    /technical name "SQLCipher" count decreased \(1 -> 0\)/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "WAL remains enabled. SQLCipher remains deferred.",
    "WAL 保持启用。SQLCipher 仍然延期。",
    "fixture",
  ));
});

test("rejects duplicated adjacent Chinese phrases", () => {
  assert.throws(
    () => validateTranslationQuality("Verify the result.", "验证结果验证结果。", "fixture"),
    /adjacent Chinese phrase was duplicated/,
  );
});

test("rejects substantial unchanged English prose across line wrapping", () => {
  const original = "The protected deployment workflow must verify the exact immutable candidate before exposing any production credential.";
  const copied = "The protected deployment workflow must verify the exact immutable candidate\nbefore exposing any production credential.";
  assert.throws(
    () => validateTranslationQuality(original, copied, "fixture"),
    /fixture: substantial English prose copied unchanged|short English prose copied unchanged/,
  );
});

test("allows an unchanged list made only of protected technical names", () => {
  const technicalNames = "Pakperk Rust Flutter API OIDC Keycloak PostgreSQL Kubernetes Helm OpenTelemetry Android iOS";
  assert.doesNotThrow(() => validateTranslationQuality(technicalNames, technicalNames, "fixture"));
});

test("normalizes audited calques in prose without changing protected examples", () => {
  const exampleSource = "Test accessibility and preserve `可访问性` in the example.";
  const normalized = normalizeTranslationTerminology(
    exampleSource,
    "**辅助功能:** 请测试可访问性，并保留 `可访问性` 示例。",
    "fixture",
    "mobile-device-development.md",
  );
  assert.equal(normalized, "**辅助功能：** 请测试无障碍，并保留 `可访问性` 示例。");

  assert.equal(
    normalizeTranslationTerminology(
      "Use Drift over SQLite with a fresh reader-state key.",
      "使用 Drift 而不是 SQLite，并创建阅读器密钥。",
      "fixture",
      "adr/0002-drift-local-database.md",
    ),
    "使用基于 SQLite 的 Drift，并创建状态键。",
  );

  assert.equal(
    normalizeTranslationTerminology(
      "# Account authentication and profile contract",
      "# 账户身份认证与个人资料契约",
      "account-authentication.md part 1/6",
      "account-authentication.md",
    ),
    "# 账户身份认证与个人资料契约",
  );

  for (const input of ["配置 Keycloak 域。", "配置 Keycloak 领域。", "配置 Keycloak realm。"]) {
    assert.equal(
      normalizeTranslationTerminology(
        "Configure the Keycloak realm.",
        input,
        "fixture",
        "account-authentication.md",
      ),
      "配置 Keycloak Realm。",
    );
  }
});

test("normalizes Drift schema migrations and sync outbox prose without changing a mode migration", () => {
  const driftSource =
    "Production needs schema migrations and a durable sync outbox.";
  const literalTranslation =
    "生产环境需要模式迁移和持久化的同步待同步队列 outbox。";
  const normalized = normalizeTranslationTerminology(
    driftSource,
    literalTranslation,
    "Drift schema and outbox",
    "adr/0002-drift-local-database.md",
  );

  assert.equal(
    normalized,
    "生产环境需要 schema 迁移和持久化的待同步队列（outbox）。",
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    driftSource,
    normalized,
    "Drift schema and outbox",
    "adr/0002-drift-local-database.md",
  ));

  const acceptedDatabaseSchema = "生产环境需要数据库模式迁移和持久化待同步队列（outbox）。";
  assert.equal(
    normalizeTranslationTerminology(
      driftSource,
      acceptedDatabaseSchema,
      "accepted database schema migration",
      "adr/0002-drift-local-database.md",
    ),
    acceptedDatabaseSchema,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    driftSource,
    acceptedDatabaseSchema,
    "accepted database schema migration",
    "adr/0002-drift-local-database.md",
  ));

  const modeSource = "The display mode migration remains optional.";
  const modeTranslation = "显示模式迁移仍为可选。";
  assert.equal(
    normalizeTranslationTerminology(
      modeSource,
      modeTranslation,
      "unrelated mode migration",
      "adr/0002-drift-local-database.md",
    ),
    modeTranslation,
  );
});

test("normalizes database schema version and schema clauses without changing UI or WAL modes", () => {
  const sourceText =
    "The production database currently has schema version 10. The database uses WAL mode. The schema contains three tables.";
  const literalTranslation =
    "生产数据库当前模式版本为 10。数据库使用 WAL 模式。模式包含三个表。";
  const expected =
    "生产数据库当前 schema 版本为 10。数据库使用 WAL 模式。schema 包含三个表。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    literalTranslation,
    "database schema shape",
    "adr/0002-drift-local-database.md",
  );

  assert.equal(normalized, expected);
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "database schema shape",
    "adr/0002-drift-local-database.md",
  ));

  const modeCases = [
    ["The display mode version remains stable.", "显示模式版本保持稳定。"],
    ["The display mode contains two options.", "模式包含两个显示选项。"],
    ["The database remains in WAL mode.", "数据库保持 WAL 模式。"],
  ];
  for (const [modeSource, modeTranslation] of modeCases) {
    assert.equal(
      normalizeTranslationTerminology(
        modeSource,
        modeTranslation,
        "unrelated mode phrase",
        "adr/0002-drift-local-database.md",
      ),
      modeTranslation,
    );
  }
});

test("accepts subjectless Chinese for schema persistence behavior without weakening schema terms", () => {
  const behaviorSource = `- The schema persists idempotent save/unsave operations in an outbox while
  offline, and Phase 4 owns their guarded synchronization behavior. Public
  comment drafts remain distinct from the outbox and never auto-publish.`;
  const subjectlessTranslation =
    "- 离线时，幂等的保存/取消保存操作会持久化到待同步队列（outbox）中，Phase 4 负责其受保护的同步行为。公开评论草稿始终与待同步队列（outbox）区分开，并且绝不会自动发布。";

  assert.doesNotThrow(() => validateTranslationQuality(
    behaviorSource,
    subjectlessTranslation,
    "subjectless schema persistence behavior",
    "adr/0002-drift-local-database.md",
  ));

  assert.throws(
    () => validateTranslationQuality(
      behaviorSource,
      subjectlessTranslation.replace("会持久化到", "会进入"),
      "missing schema persistence meaning",
      "adr/0002-drift-local-database.md",
    ),
    /required terminology "schema"/,
  );
  assert.throws(
    () => validateTranslationQuality(
      "The schema contains three tables.",
      "该数据库包含三个表。",
      "missing explicit schema term",
      "adr/0002-drift-local-database.md",
    ),
    /required terminology "schema"/,
  );
});

test("normalizes the complete historical schema-fixture migration sentence only", () => {
  const sourceText =
    "Migrations are explicit and tested from complete historical schema fixtures through version 10.";
  const mistranslations = [
    "数据库迁移是显式的，并从完整的原始模式快照测试到版本 10。",
    "数据库迁移是显式且经过测试的，从完整的原始模式快照开始，一直到版本 10。",
  ];
  const expected =
    "数据库迁移均显式定义，并使用完整的历史数据库模式测试夹具完成截至版本 10 的迁移测试。";
  for (const [index, mistranslation] of mistranslations.entries()) {
    const normalized = normalizeTranslationTerminology(
      sourceText,
      mistranslation,
      `historical schema fixtures variant ${index + 1}`,
      "adr/0002-drift-local-database.md",
    );

    assert.equal(normalized, expected);
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      normalized,
      `historical schema fixtures variant ${index + 1}`,
      "adr/0002-drift-local-database.md",
    ));
  }
  assert.equal(
    normalizeTranslationTerminology(
      sourceText,
      expected,
      "already-correct historical schema fixtures",
      "adr/0002-drift-local-database.md",
    ),
    expected,
  );

  const unrelatedSource =
    "Migrations use complete original schema snapshots through version 10.";
  assert.equal(
    normalizeTranslationTerminology(
      unrelatedSource,
      mistranslations[1],
      "unrelated schema snapshots",
      "adr/0002-drift-local-database.md",
    ),
    mistranslations[1],
  );
});

test("enforces unambiguous Drift cache bounds and saved-paper pinning terms", () => {
  const acceptedCases = [
    ["Use bounded cache eviction.", "使用有界缓存淘汰机制。"],
    ["Measure cache capacity.", "测量缓存容量。"],
    ["Use saved-paper pinning.", "固定保留已保存的论文。"],
  ];
  for (const [sourceText, translation] of acceptedCases) {
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      translation,
      "Drift cache terminology",
      "adr/0002-drift-local-database.md",
    ));
  }

  const rejectedCases = [
    ["Use bounded cache eviction.", "使用缓存淘汰机制。", "bounded cache"],
    ["Measure cache capacity.", "测量容量。", "cache capacity"],
    ["Use saved-paper pinning.", "保存论文。", "saved-paper pinning"],
  ];
  for (const [sourceText, translation, sourceLabel] of rejectedCases) {
    assert.throws(
      () => validateTranslationQuality(
        sourceText,
        translation,
        "missing Drift cache terminology",
        "adr/0002-drift-local-database.md",
      ),
      new RegExp(`required terminology ${JSON.stringify(sourceLabel)}`),
    );
  }

  assert.doesNotThrow(() => validateTranslationQuality(
    "The capacity of the room is bounded by the fire code.",
    "房间容量受消防规范限制。",
    "ordinary bounded capacity",
    "developer-guide.md",
  ));
});

test("normalizes an intervening Drift-over-SQLite alternative without touching unrelated choices", () => {
  const sourceText = "Use Drift over SQLite as the mobile content database.";
  const backwardsTranslation = "使用 Drift 作为移动端内容数据库，而不是 SQLite。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    backwardsTranslation,
    "Drift over SQLite sentence",
    "adr/0002-drift-local-database.md",
  );

  assert.equal(normalized, "使用基于 SQLite 的 Drift 作为移动端内容数据库。");
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "Drift over SQLite sentence",
    "adr/0002-drift-local-database.md",
  ));
  assert.throws(
    () => validateTranslationQuality(
      sourceText,
      backwardsTranslation,
      "backwards Drift over SQLite sentence",
      "adr/0002-drift-local-database.md",
    ),
    /known bad calque \(Drift presented as an alternative to SQLite\)/,
  );

  const unrelatedSource = "Compare Drift and SQLite as independent benchmark alternatives.";
  const unrelatedTranslation = "将 Drift 和 SQLite 作为彼此独立的基准测试备选方案进行比较。";
  assert.equal(
    normalizeTranslationTerminology(
      unrelatedSource,
      unrelatedTranslation,
      "unrelated database alternatives",
      "adr/0002-drift-local-database.md",
    ),
    unrelatedTranslation,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    unrelatedSource,
    unrelatedTranslation,
    "unrelated database alternatives",
    "adr/0002-drift-local-database.md",
  ));
});

test("counts terminal sentences rather than semicolon style for omission coverage", () => {
  const sourceText = `Use Drift over SQLite as the mobile content database. It owns relational public
cache data, saved-paper projections, comment cache, drafts, cache metadata, and
the retry outbox. SharedPreferences remains only for small scalar preferences
and selected restoration metadata. Authentication tokens are not stored in
Drift; they remain in platform secure storage.`;
  const translation = `使用基于 SQLite 的 Drift 作为移动端内容数据库。它负责关系型公共缓存数据、已保存论文投影、评论缓存、草稿、缓存元数据以及重试待同步队列（outbox）。SharedPreferences 仅用于小型标量偏好设置和选定的恢复元数据。身份认证令牌不存储在 Drift 中，而是保留在平台安全存储中。`;

  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    translation,
    "Drift decision paragraph",
    "adr/0002-drift-local-database.md",
  ));
  assert.throws(
    () => validateTranslationQuality(
      sourceText,
      translation.replace("它负责关系型公共缓存数据、已保存论文投影、评论缓存、草稿、缓存元数据以及重试待同步队列（outbox）。", ""),
      "Drift paragraph with omitted sentence",
      "adr/0002-drift-local-database.md",
    ),
    /sentence\/clause markers decreased/,
  );
});

test("normalizes restored sync-outbox literals while preserving durability", () => {
  const cases = [
    [
      "Transactions require a durable sync outbox.",
      "事务需要持久化的同步 outbox。",
      "事务需要持久化的待同步队列（outbox）。",
    ],
    [
      "Transactions require a durable sync outbox.",
      "事务需要持久化同步 outbox。",
      "事务需要持久化的待同步队列（outbox）。",
    ],
    [
      "Transactions require a sync outbox.",
      "事务需要同步 outbox。",
      "事务需要待同步队列（outbox）。",
    ],
    [
      "The database owns the retry outbox.",
      "数据库负责重试 outbox。",
      "数据库负责重试待同步队列（outbox）。",
    ],
    [
      "Remove pending research outbox work on sign-out.",
      "退出登录时移除待处理的研究 outbox 工作。",
      "退出登录时移除待处理的研究待同步队列（outbox）工作。",
    ],
  ];

  for (const [sourceText, literalTranslation, expected] of cases) {
    const normalized = normalizeTranslationTerminology(
      sourceText,
      literalTranslation,
      "restored sync outbox",
      "adr/0002-drift-local-database.md",
    );
    assert.equal(normalized, expected);
    assert.equal(
      normalizeTranslationTerminology(
        sourceText,
        normalized,
        "idempotent sync outbox",
        "adr/0002-drift-local-database.md",
      ),
      expected,
    );
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      normalized,
      "restored sync outbox",
      "adr/0002-drift-local-database.md",
    ));
  }

  const alreadyCorrect = "事务需要持久化的待同步队列（outbox）。";
  assert.equal(
    normalizeTranslationTerminology(
      "Transactions require a durable sync outbox.",
      alreadyCorrect,
      "already-correct sync outbox",
      "adr/0002-drift-local-database.md",
    ),
    alreadyCorrect,
  );

  assert.throws(
    () => validateTranslationQuality(
      "Production needs a durable sync outbox.",
      "生产环境需要待同步队列（outbox）。",
      "durability omitted from sync outbox",
      "adr/0002-drift-local-database.md",
    ),
    /required terminology "durable sync outbox"/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "Production needs a durable sync outbox.",
    "生产环境需要持久化待同步队列（outbox）。",
    "durable sync outbox",
    "adr/0002-drift-local-database.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "Production needs a sync outbox.",
    "生产环境需要待同步队列（outbox）。",
    "non-durable sync outbox",
    "adr/0002-drift-local-database.md",
  ));

  for (const [mailSource, mailboxTranslation] of [
    ["The mailbox outbox keeps sent messages.", "邮箱发件箱保存已发送邮件。"],
    ["The email outbox keeps sent messages.", "电子邮件发件箱保存已发送邮件。"],
  ]) {
    assert.equal(
      normalizeTranslationTerminology(
        mailSource,
        mailboxTranslation,
        "mailbox outbox",
        "adr/0002-drift-local-database.md",
      ),
      mailboxTranslation,
    );
    assert.doesNotThrow(() => validateTranslationQuality(
      mailSource,
      mailboxTranslation,
      "mailbox outbox",
      "adr/0002-drift-local-database.md",
    ));
  }

  const protectedSource = "Use the retry outbox and preserve `outbox` in the example.\n\n```text\noutbox\n```";
  const protectedTranslation = "使用重试 outbox，并在示例中保留 `outbox`。\n\n```text\noutbox\n```";
  assert.equal(
    normalizeTranslationTerminology(
      protectedSource,
      protectedTranslation,
      "protected outbox examples",
      "adr/0002-drift-local-database.md",
    ),
    "使用重试待同步队列（outbox），并在示例中保留 `outbox`。\n\n```text\noutbox\n```",
  );
});

test("enforces OIDC not-before timing without reversing its meaning", () => {
  const sourceText = "OIDC token validation enforces expiration/not-before.";
  for (const accepted of [
    "OIDC 令牌验证会强制执行过期时间和不得早于指定时间生效约束。",
    "OIDC 令牌验证会强制执行过期时间和生效时间下限。",
    "OIDC 令牌验证会强制执行过期时间和 not-before 约束。",
  ]) {
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      accepted,
      "OIDC not-before",
      "adr/0001-oidc-and-keycloak-reference.md",
    ));
  }

  for (const reversed of ["未过期前", "未过期时间"]) {
    assert.throws(
      () => validateTranslationQuality(
        sourceText,
        `OIDC 令牌验证会强制执行过期时间和${reversed}约束。`,
        "reversed OIDC not-before",
        "adr/0001-oidc-and-keycloak-reference.md",
      ),
      /known bad calque \(OIDC not-before translated with reversed timing\)/,
    );
  }
  assert.throws(
    () => validateTranslationQuality(
      sourceText,
      "OIDC 令牌验证会检查过期时间。",
      "missing OIDC not-before",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    /required terminology "OIDC not-before"/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "Complete setup before the token expires.",
    "请在令牌过期前完成设置。",
    "ordinary before",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));
});

test("enforces brute-force protection without matching ordinary physical force", () => {
  for (const [sourceText, accepted] of [
    ["Enable brute-force protection.", "启用暴力破解防护。"],
    ["Enable brute force protection.", "启用防暴力破解机制。"],
  ]) {
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      accepted,
      "brute-force protection",
      "adr/0001-oidc-and-keycloak-reference.md",
    ));
  }
  assert.throws(
    () => validateTranslationQuality(
      "Enable brute-force protection.",
      "启用暴力保护。",
      "vague brute-force protection",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    /known bad calque \(brute-force protection translated as vague force protection\)/,
  );
  assert.throws(
    () => validateTranslationQuality(
      "Enable brute-force protection.",
      "启用账户保护。",
      "missing brute-force protection",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    /required terminology "brute-force protection"/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "Physical brute force can damage the enclosure.",
    "物理蛮力可能损坏外壳。",
    "ordinary physical force",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));
});

test("normalizes lowercase Authorization-header prose and rejects vague authorization heads", () => {
  const sourceText = "Token contents and authorization headers never appear in logs.";
  const vagueTranslation = "令牌内容和授权头绝不会出现在日志中。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    vagueTranslation,
    "lowercase authorization headers",
    "adr/0001-oidc-and-keycloak-reference.md",
  );

  assert.equal(normalized, "令牌内容和 Authorization 请求头绝不会出现在日志中。");
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "lowercase authorization headers",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));
  for (const vague of ["授权头", "授权请求头"]) {
    assert.throws(
      () => validateTranslationQuality(
        sourceText,
        `令牌内容和${vague}绝不会出现在日志中。`,
        "vague authorization header",
        "adr/0001-oidc-and-keycloak-reference.md",
      ),
      /known bad calque \(Authorization header translated as a vague authorization head\)/,
    );
  }

  const ordinaryAuthorizationSource = "The committee granted authorization to publish.";
  const ordinaryAuthorizationTranslation = "委员会授予了发布授权。";
  assert.equal(
    normalizeTranslationTerminology(
      ordinaryAuthorizationSource,
      ordinaryAuthorizationTranslation,
      "ordinary authorization",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    ordinaryAuthorizationTranslation,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    ordinaryAuthorizationSource,
    ordinaryAuthorizationTranslation,
    "ordinary authorization",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));
});

test("normalizes visible delta-seconds table prose without changing code or HTTP header tokens", () => {
  const tableSource = `| Status | Retry metadata |
| --- | --- |
| 429 | delta-seconds \`Retry-After\` |
`;
  const literalTableTranslation = `| 状态 | 重试元数据 |
| --- | --- |
| 429 | delta-seconds \`Retry-After\` |
`;
  const normalizedTable = normalizeTranslationTerminology(
    tableSource,
    literalTableTranslation,
    "account retry table",
    "account-authentication.md",
  );

  assert.equal(normalizedTable, `| 状态 | 重试元数据 |
| --- | --- |
| 429 | 秒数差值 \`Retry-After\` |
`);
  assert.doesNotThrow(() => validateTranslationQuality(
    tableSource,
    normalizedTable,
    "account retry table",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "Return a delta-seconds Retry-After value.",
    "返回以秒为单位的差值作为 Retry-After 值。",
    "accepted delta-seconds synonym",
    "account-authentication.md",
  ));

  const tokenSource =
    "Describe delta-seconds and delta seconds; preserve `delta-seconds`, `Retry-After`, and X-Delta-Seconds.";
  const tokenTranslation =
    "说明 delta-seconds 和 delta seconds；保留 `delta-seconds`、`Retry-After` 和 X-Delta-Seconds。";
  assert.equal(
    normalizeTranslationTerminology(
      tokenSource,
      tokenTranslation,
      "protected delta-seconds tokens",
      "account-authentication.md",
    ),
    "说明秒数差值和秒数差值；保留 `delta-seconds`、`Retry-After` 和 X-Delta-Seconds。",
  );
});

test("normalizes Pakperk library route and gate prose without changing ordinary libraries", () => {
  const sourceText =
    "Phase 4 now publishes library routes only when its independent account, library, and write gates allow them.";
  const literalTranslation =
    "Phase 4 现在仅在独立的账户、图书馆和写入门禁允许时发布图书馆路由。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    literalTranslation,
    "account library gates",
    "account-authentication.md",
  );

  assert.equal(
    normalized,
    "Phase 4 现在仅在独立的账户、Library 和写入门禁允许时发布 Library 路由。",
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "account library gates",
    "account-authentication.md",
  ));

  const ordinaryLibraries = [
    ["The physical library remains open.", "实体图书馆保持开放。"],
    ["The Rust library routes requests through an adapter.", "Rust 库通过适配器路由请求。"],
    ["This software library routes requests through an adapter.", "这个软件库通过适配器路由请求。"],
  ];
  for (const [ordinarySource, ordinaryTranslation] of ordinaryLibraries) {
    assert.equal(
      normalizeTranslationTerminology(
        ordinarySource,
        ordinaryTranslation,
        "ordinary library",
        "account-authentication.md",
      ),
      ordinaryTranslation,
    );
    assert.doesNotThrow(() => validateTranslationQuality(
      ordinarySource,
      ordinaryTranslation,
      "ordinary library",
      "account-authentication.md",
    ));
  }
});

test("normalizes only the historical library routes under You", () => {
  const sourceText = `Paper detail routes belonged under Read; account and then-current library routes belonged
under You.`;
  const mistranslation =
    "论文详情路由属于 Read；账户和当前库路由属于 You。";
  const expected =
    "论文详情路由属于 Read；账户和当时的个人论文库路由属于 You。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    mistranslation,
    "historical Library routes",
    "adr/0003-stateful-shell-routing.md",
  );

  assert.equal(normalized, expected);
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "historical Library routes",
    "adr/0003-stateful-shell-routing.md",
  ));
  assert.equal(
    normalizeTranslationTerminology(
      sourceText,
      expected,
      "already-correct historical Library routes",
      "adr/0003-stateful-shell-routing.md",
    ),
    expected,
  );

  const currentSource = "The current library route is documented separately.";
  const currentTranslation = "当前库路由另有文档说明。";
  assert.equal(
    normalizeTranslationTerminology(
      currentSource,
      currentTranslation,
      "current Library route",
      "adr/0003-stateful-shell-routing.md",
    ),
    currentTranslation,
  );
});

test("normalizes only an older restored You session", () => {
  const sourceText =
    "Keeping persistence identity separate from display order prevents an older restored You session from reopening in Library.";
  const mistranslation =
    "将持久化标识与显示顺序分离，可避免旧的 You 会话在 Library 中重新打开。";
  const expected =
    "将持久化标识与显示顺序分离，可避免旧版中恢复的 You 会话在 Library 中重新打开。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    mistranslation,
    "older restored You session",
    "adr/0003-stateful-shell-routing.md",
  );

  assert.equal(normalized, expected);
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "older restored You session",
    "adr/0003-stateful-shell-routing.md",
  ));
  assert.equal(
    normalizeTranslationTerminology(
      sourceText,
      expected,
      "already-correct restored You session",
      "adr/0003-stateful-shell-routing.md",
    ),
    expected,
  );

  const unrelatedSource = "An older You session remains available.";
  const unrelatedTranslation = "旧的 You 会话仍然可用。";
  assert.equal(
    normalizeTranslationTerminology(
      unrelatedSource,
      unrelatedTranslation,
      "ordinary older You session",
      "adr/0003-stateful-shell-routing.md",
    ),
    unrelatedTranslation,
  );
});

test("preserves Introduction and Connections only in ADR reader-stage contexts", () => {
  const adr2Source =
    "Processing-generation changes prevent late Introduction, Connections, or chat responses from crossing a retry boundary.";
  const exactTranslation =
    "处理代次变更可防止迟到的 Introduction、Connections 或聊天响应跨越重试边界。";
  assert.doesNotThrow(() => validateTranslationQuality(
    adr2Source,
    exactTranslation,
    "ADR reader-stage labels",
    "adr/0002-drift-local-database.md",
  ));
  assert.throws(
    () => validateTranslationQuality(
      adr2Source,
      "处理代次变更可防止迟到的引言、Connections 或聊天响应跨越重试边界。",
      "translated Introduction stage",
      "adr/0002-drift-local-database.md",
    ),
    /Pakperk UI label "Introduction" count decreased/,
  );
  assert.throws(
    () => validateTranslationQuality(
      adr2Source,
      "处理代次变更可防止迟到的 Introduction、关联内容或聊天响应跨越重试边界。",
      "translated Connections stage",
      "adr/0002-drift-local-database.md",
    ),
    /Pakperk UI label "Connections" count decreased/,
  );

  assert.doesNotThrow(() => validateTranslationQuality(
    "Introduction to the system explains connections between modules.",
    "系统简介说明了模块之间的联系。",
    "ordinary introduction and connections",
    "developer-guide.md",
  ));
});

test("preserves routing surface identities only in ADR0003", () => {
  const sourceText =
    "The visible primary destinations are now Read, Library, and You. Ordinary public links begin on Abstract.";
  const exactTranslation =
    "当前可见的主要目的地为 Read、Library 和 You。普通公开链接从 Abstract 开始。";
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    exactTranslation,
    "ADR0003 routing identities",
    "adr/0003-stateful-shell-routing.md",
  ));

  for (const [label, translatedLabel] of [
    ["Read", "阅读"],
    ["You", "个人中心"],
    ["Abstract", "摘要"],
  ]) {
    assert.throws(
      () => validateTranslationQuality(
        sourceText,
        exactTranslation.replace(label, translatedLabel),
        `translated ${label} routing identity`,
        "adr/0003-stateful-shell-routing.md",
      ),
      new RegExp(`Pakperk UI label ${JSON.stringify(label)} count decreased`),
    );
  }

  const ordinarySource = "Read this note. You can compare Abstract concepts.";
  const ordinaryTranslation = "阅读此说明。您可以比较抽象概念。";
  for (const relativePath of [
    "adr/0002-drift-local-database.md",
    "developer-guide.md",
  ]) {
    assert.doesNotThrow(() => validateTranslationQuality(
      ordinarySource,
      ordinaryTranslation,
      "ordinary Read, You, and Abstract",
      relativePath,
    ));
  }
});

test("normalizes operational alerts without changing a nontechnical alarm alert", () => {
  const sourceText =
    "They remain default-off until the target provider grant, independent ledger/backup topology, restore drill, alerts, and public disclosures have approved evidence.";
  const literalTranslation =
    "在目标提供商授权、独立账本/备份拓扑、恢复演练、警报和公开披露获得批准证据之前，它们保持默认关闭。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    literalTranslation,
    "account operational alerts",
    "account-authentication.md",
  );

  assert.equal(
    normalized,
    "在目标提供商授权、独立账本/备份拓扑、恢复演练、告警和公开披露获得批准证据之前，它们保持默认关闭。",
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "account operational alerts",
    "account-authentication.md",
  ));

  const alarmSource = "The smoke-alarm alert warns visitors.";
  const alarmTranslation = "烟雾报警器的警报会提醒访客。";
  assert.equal(
    normalizeTranslationTerminology(
      alarmSource,
      alarmTranslation,
      "nontechnical alarm alert",
      "account-authentication.md",
    ),
    alarmTranslation,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    alarmSource,
    alarmTranslation,
    "nontechnical alarm alert",
    "account-authentication.md",
  ));
});

test("normalizes public-user handles without changing OS, file, or request handles", () => {
  const sourceText = "Saving does not require a handle.";
  const literalTranslation = "保存不需要句柄。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    literalTranslation,
    "account handle",
    "account-authentication.md",
  );

  assert.equal(normalized, "保存不需要用户名。");
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "account handle",
    "account-authentication.md",
  ));

  const technicalHandles = [
    ["The OS requires a handle.", "操作系统需要句柄。"],
    ["Close the file handle after use.", "使用后关闭文件句柄。"],
    ["The request handle remains opaque.", "请求句柄保持不透明。"],
  ];
  for (const [technicalSource, technicalTranslation] of technicalHandles) {
    assert.equal(
      normalizeTranslationTerminology(
        technicalSource,
        technicalTranslation,
        "technical handle",
        "account-authentication.md",
      ),
      technicalTranslation,
    );
    assert.doesNotThrow(() => validateTranslationQuality(
      technicalSource,
      technicalTranslation,
      "technical handle",
      "account-authentication.md",
    ));
  }

  const publicHandleSource =
    "Pakperk gains a local user record and public handle independent of provider display data, avoiding authorization based on client-supplied profile fields.";
  for (const mistranslatedHandle of ["公开标识", "公共标识"]) {
    const literalPublicHandle =
      `Pakperk 会获得一个与提供方显示数据无关的本地用户记录和${mistranslatedHandle}，避免基于客户端提供的资料字段进行授权。`;
    const normalizedPublicHandle = normalizeTranslationTerminology(
      publicHandleSource,
      literalPublicHandle,
      "ADR public handle",
      "adr/0001-oidc-and-keycloak-reference.md",
    );
    assert.equal(
      normalizedPublicHandle,
      "Pakperk 会获得一个与提供方显示数据无关的本地用户记录和公开用户名，避免基于客户端提供的资料字段进行授权。",
    );
    assert.doesNotThrow(() => validateTranslationQuality(
      publicHandleSource,
      normalizedPublicHandle,
      "ADR public handle",
      "adr/0001-oidc-and-keycloak-reference.md",
    ));
  }

  const publicIdentifierSource = "The API publishes a public identifier for the dataset.";
  const publicIdentifierTranslation = "API 为数据集发布公开标识。";
  assert.equal(
    normalizeTranslationTerminology(
      publicIdentifierSource,
      publicIdentifierTranslation,
      "unrelated public identifier",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    publicIdentifierTranslation,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    publicIdentifierSource,
    publicIdentifierTranslation,
    "unrelated public identifier",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));
});

test("normalizes only a source-gated Keycloak realm and leaves ordinary domains unchanged", () => {
  assert.doesNotThrow(() => validateTranslationQuality(
    "Configure the Keycloak realm.",
    "配置 Keycloak Realm。",
    "fixture",
    "account-authentication.md",
  ));
  assert.equal(
    normalizeTranslationTerminology(
      "A fantasy realm and a network domain are unrelated.",
      "奇幻领域与网络域无关。",
      "fixture",
      "account-authentication.md",
    ),
    "奇幻领域与网络域无关。",
  );

  assert.equal(
    normalizeTranslationTerminology(
      "The Keycloak realm and provider remain configured.",
      "Keycloak 领域以及提供商保持已配置状态。",
      "Keycloak realm adjacency",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    "Keycloak Realm 以及提供商保持已配置状态。",
  );
  assert.equal(
    normalizeTranslationTerminology(
      "The Keycloak realm and provider remain configured.",
      "Keycloak Realm 以及提供商保持已配置状态。",
      "accepted Keycloak Realm",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    "Keycloak Realm 以及提供商保持已配置状态。",
  );
});

test("normalizes a literal single-flight refresh without changing one-time refresh prose", () => {
  const sourceText = "An unknown signing key ID triggers a single-flight refresh request, subject to a cooldown.";
  const literalTranslation = "未知的签名密钥 ID 将触发一次单次刷新请求，并受冷却时间限制。";
  const normalized = normalizeTranslationTerminology(
    sourceText,
    literalTranslation,
    "fixture",
    "account-authentication.md",
  );
  assert.equal(normalized, "未知的签名密钥 ID 将触发合并并发刷新请求，并受冷却时间限制。");
  assert.doesNotThrow(() => validateTranslationQuality(
    sourceText,
    normalized,
    "fixture",
    "account-authentication.md",
  ));

  assert.equal(
    normalizeTranslationTerminology(
      sourceText,
      "未知的签名密钥 ID 将触发一次单次刷新，受冷却时间限制。",
      "fixture",
      "account-authentication.md",
    ),
    "未知的签名密钥 ID 将触发合并并发刷新请求，受冷却时间限制。",
  );

  assert.equal(
    normalizeTranslationTerminology(
      "An unknown signing key ID triggers a one-time refresh request.",
      "未知的签名密钥 ID 将触发一次刷新请求。",
      "fixture",
      "account-authentication.md",
    ),
    "未知的签名密钥 ID 将触发一次刷新请求。",
  );
});

test("normalizes identity subjects without double expansion or grammatical collisions", () => {
  const sourceText =
    "Tokens, authorization codes, PKCE verifiers, OIDC subjects, and profile data never appear in logs.";
  const literalTranslation =
    "令牌、授权码、PKCE 验证器、OIDC 主体和资料数据不会出现在日志中。";
  const expected =
    "令牌、授权码、PKCE 验证器、OIDC 主体标识和资料数据不会出现在日志中。";
  assert.equal(
    normalizeTranslationTerminology(
      sourceText,
      literalTranslation,
      "fixture",
      "account-authentication.md",
    ),
    expected,
  );
  assert.equal(
    normalizeTranslationTerminology(
      sourceText,
      expected,
      "fixture",
      "account-authentication.md",
    ),
    expected,
  );
  assert.equal(
    normalizeTranslationTerminology(
      "The provider subject identifies the account.",
      "身份提供商主体用于标识账户。",
      "fixture",
      "account-authentication.md",
    ),
    "身份提供商主体标识用于标识账户。",
  );
  assert.equal(
    normalizeTranslationTerminology(
      "The subject remains under review.",
      "该主题仍在审核中。",
      "fixture",
      "account-authentication.md",
    ),
    "该主题仍在审核中。",
  );

  const requiredSubjectSource =
    "The API validates tokens using OIDC discovery and JWKS, including signature, allowed algorithm, issuer, audience, expiration/not-before, clock skew, and a required subject.";
  for (const requiredSubject of ["必需的主体", "要求的主体"]) {
    assert.equal(
      normalizeTranslationTerminology(
        requiredSubjectSource,
        `API 使用 OIDC 发现和 JWKS 验证令牌，包括签名、允许的算法、颁发者、受众、过期时间/未生效时间、时钟偏移以及${requiredSubject}。`,
        "required OIDC subject",
        "adr/0001-oidc-and-keycloak-reference.md",
      ),
      `API 使用 OIDC 发现和 JWKS 验证令牌，包括签名、允许的算法、颁发者、受众、过期时间/未生效时间、时钟偏移以及${requiredSubject}标识。`,
    );
  }
  const acceptedRequiredSubject =
    "API 使用 OIDC 发现和 JWKS 验证令牌，包括签名、允许的算法、颁发者、受众、过期时间/生效时间下限、时钟偏移以及必需的主体标识。";
  assert.equal(
    normalizeTranslationTerminology(
      requiredSubjectSource,
      acceptedRequiredSubject,
      "accepted required OIDC subject",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    acceptedRequiredSubject,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    requiredSubjectSource,
    acceptedRequiredSubject,
    "accepted required OIDC subject",
    "adr/0001-oidc-and-keycloak-reference.md",
  ));
  assert.equal(
    normalizeTranslationTerminology(
      "The required subject for the essay is history.",
      "这篇文章要求的主题是历史。",
      "unrelated required subject",
      "adr/0001-oidc-and-keycloak-reference.md",
    ),
    "这篇文章要求的主题是历史。",
  );
});

test("terminology errors include a bounded head, relevant middle, and tail overview", () => {
  const noisyTranslation = `Keycloak 错误译文：${Array.from({ length: 80 }, (_, index) => `条目${index}`).join("，")}\n第二行`;
  assert.throws(
    () => validateTranslationQuality(
      "Configure the Keycloak realm.",
      noisyTranslation,
      "diagnostic fixture",
      "account-authentication.md",
    ),
    (error) => {
      const match = error.message.match(/translation: (".*")$/u);
      assert.ok(match);
      const excerpt = JSON.parse(match[1]);
      assert.match(excerpt, /^Keycloak 错误译文：条目0/u);
      assert.match(excerpt, /条目(?:3|4)\d/u);
      assert.match(excerpt, /条目79 第二行$/u);
      assert.equal((excerpt.match(/…/gu) || []).length, 2);
      assert.ok([...excerpt].length <= 240);
      assert.doesNotMatch(error.message, /\r|\n/);
      return true;
    },
  );

  const failClosedSource =
    "Genuine unscoped v1 derived/chat blobs fail closed instead of borrowing newer provenance.";
  const cueTranslation =
    `${Array.from({ length: 70 }, (_, index) => `前部说明${index}`).join("，")}，` +
    "真正无作用域的 v1 派生/聊天 blob 失败时会关闭，而不是借用较新的来源信息，" +
    `${Array.from({ length: 25 }, (_, index) => `尾部说明${index}`).join("，")}。`;
  assert.throws(
    () => validateTranslationQuality(
      failClosedSource,
      cueTranslation,
      "cue diagnostic fixture",
      "adr/0002-drift-local-database.md",
    ),
    (error) => {
      const match = error.message.match(/translation: (".*")$/u);
      assert.ok(match);
      const excerpt = JSON.parse(match[1]);
      assert.match(excerpt, /^前部说明0/u);
      assert.match(excerpt, /失败时会关闭/u);
      assert.match(excerpt, /尾部说明24。$/u);
      assert.ok([...excerpt].length <= 240);
      assert.doesNotMatch(error.message, /\r|\n/);
      return true;
    },
  );
});

test("accepts an idiomatic profile-contract heading while keeping API contract strict", () => {
  assert.doesNotThrow(() => validateTranslationQuality(
    "# Account authentication and profile contract",
    "# 账户身份认证与用户资料契约",
    "fixture",
    "account-authentication.md",
  ));
  assert.throws(
    () => validateTranslationQuality(
      "# API contract",
      "# API 合同",
      "fixture",
      "account-authentication.md",
    ),
    /required terminology "technical contract"/,
  );
});

test("accepts professional authentication variants while keeping authorization distinct", () => {
  assert.doesNotThrow(() => validateTranslationQuality(
    "Authentication and authorization remain distinct.",
    "身份验证与授权保持不同。",
    "fixture",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "# Account authentication and profile contract",
    "# 账户身份验证与用户资料契约",
    "fixture",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "# Account authentication and profile contract",
    "# 账户认证与用户资料契约",
    "account-authentication.md part 1/6",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "# Account authentication and profile contract",
    "# 用户认证与用户资料契约",
    "fixture",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "# Authentication",
    "# 认证",
    "fixture",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "Limit the authentication scope.",
    "限制身份验证范围。",
    "fixture",
    "account-authentication.md",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "Limit the authentication scope.",
    "限制账户认证作用域。",
    "fixture",
    "account-authentication.md",
  ));
  assert.throws(
    () => validateTranslationQuality(
      "Authentication and authorization remain distinct.",
      "身份验证与身份验证保持不同。",
      "fixture",
      "account-authentication.md",
    ),
    /required terminology "authorization" -> "授权"/,
  );
  assert.equal(
    normalizeTranslationTerminology(
      "Authentication and authorization remain distinct.",
      "身份验证与授权保持不同。",
      "fixture",
      "account-authentication.md",
    ),
    "身份验证与授权保持不同。",
  );
});

test("does not apply identity terminology to unrelated claim, subject, or operator phrases", () => {
  assert.doesNotThrow(() => validateTranslationQuality(
    "This report does not claim production readiness.",
    "本报告并不声称生产已就绪。",
    "fixture",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "Backups remain subject to the retention policy.",
    "备份仍受保留政策约束。",
    "fixture",
  ));
  assert.doesNotThrow(() => validateTranslationQuality(
    "The operator client remains available.",
    "运维客户端仍然可用。",
    "fixture",
  ));
  assert.throws(
    () => validateTranslationQuality(
      "Validate the OIDC subject and token claim.",
      "验证 OIDC 主题和令牌主张。",
      "fixture",
      "account-authentication.md",
    ),
    /known bad calque|required terminology/,
  );
});

test("scopes specialized terminology from the explicit relative path, never the diagnostic label", () => {
  assert.match(translationSystemPrompt("account-authentication.md"), /OIDC\/token issuer=/);
  assert.doesNotMatch(translationSystemPrompt("developer-guide.md"), /OIDC\/token issuer=/);
  assert.throws(
    () => validateTranslationQualityForPath(
      "Validate the OIDC issuer.",
      "验证 OIDC 发行实体。",
      "account-authentication.md",
      "opaque diagnostic text",
    ),
    /required terminology "OIDC\/token issuer"/,
  );
  assert.doesNotThrow(() => validateTranslationQualityForPath(
    "Validate the OIDC issuer.",
    "验证 OIDC 发行实体。",
    "developer-guide.md",
    "account-authentication.md part 1/6",
  ));
});

test("does not trigger specialized rules for ordinary minimal-pair meanings", () => {
  assert.doesNotThrow(() => validateTranslationQualityForPath(
    "The actor handles the parcel while a theater audience waits.",
    "演员处理包裹，剧院观众在等待。",
    "account-authentication.md",
    "minimal pair",
  ));
  assert.doesNotThrow(() => validateTranslationQualityForPath(
    "Stage the files, roll out the pastry, and block the opening with a paper sheet.",
    "暂存文件，擀开面皮，再用纸张堵住开口。",
    "backend-deployment.md",
    "minimal pair",
  ));
});

test("distinguishes a feature switch from a release approval gate", () => {
  assert.doesNotThrow(() => validateTranslationQuality(
    "**Feature gate:** disabled by default.",
    "**功能开关：** 默认关闭。",
    "fixture",
  ));
  assert.throws(
    () => validateTranslationQuality(
      "**Feature gate:** disabled by default.",
      "**发布门禁：** 默认关闭。",
      "fixture",
    ),
    /required terminology "feature gate" -> "功能开关"/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "Pass the release gate.",
    "通过发布门禁。",
    "fixture",
  ));
  assert.throws(
    () => validateTranslationQuality(
      "Pass the release gate.",
      "通过功能开关。",
      "fixture",
    ),
    /required terminology "release\/verification gate"/,
  );
});

test("accepts established professional synonyms without normalization", () => {
  const cases = [
    ["Open the deep link.", "打开深度链接。", "mobile-app-links.md"],
    ["Use a physical device.", "使用物理设备。", "mobile-device-development.md"],
    ["Configure reverse port forwarding.", "配置反向端口转发。", "mobile-device-development.md"],
    ["Restart the paper worker.", "重启论文工作线程。", "backend-deployment.md"],
    ["Configure the message broker.", "配置消息中间件。", "backend-deployment.md"],
    ["Authentication remains required.", "仍需身份验证。", "account-authentication.md"],
  ];
  for (const [sourceText, translationText, relativePath] of cases) {
    assert.doesNotThrow(() => validateTranslationQualityForPath(
      sourceText,
      translationText,
      relativePath,
      relativePath,
    ));
    assert.equal(
      normalizeTranslationTerminologyForPath(sourceText, translationText, relativePath, relativePath),
      translationText,
    );
  }
});

test("covers mobile terminology spelling variants without matching ordinary senses", () => {
  const mobilePath = "mobile-device-development.md";
  const acceptedCases = [
    ["Test on a physical iPhone.", "在实体 iPhone 上测试。"],
    ["Test on a physical iPhone.", "在 iPhone 真机上测试。"],
    ["Test on a physical phone.", "在实体手机上测试。"],
    ["Debug on a physical Android phone or iPhone.", "在 Android 实体手机或实体 iPhone 上调试。"],
    ["Grant Local Network access.", "授予本地网络访问权限。"],
    ["Grant Local Network permission.", "授予本地网络权限。"],
    ["Select the provisioning-profile.", "选择配置描述文件。"],
    ["Select the provisioning profile.", "选择预置描述文件。"],
    ["Run the dev-flavor.", "运行 dev 构建变体。"],
    ["Run the staging flavor.", "运行 staging 构建变体。"],
    ["The Android probe uses the production flavor.", "Android 探针使用 production 构建变体。"],
    ["Enable screen-reader focus.", "启用读屏软件焦点。"],
    ["Enable screen reader focus.", "启用屏幕阅读器焦点。"],
    ["Open the deep-link through Universal Links.", "通过 Universal Links 打开深层链接。"],
    ["Open the deep link.", "打开深度链接。"],
    ["Run the profile build.", "运行 Profile（性能分析）构建。"],
    ["Verify the release build.", "验证发布模式构建。"],
    ["Configure iPhone signing.", "配置 iPhone 签名。"],
  ];
  for (const [sourceText, translation] of acceptedCases) {
    assert.doesNotThrow(() => validateTranslationQualityForPath(
      sourceText,
      translation,
      mobilePath,
      "mobile terminology variant",
    ));
  }

  assert.throws(
    () => validateTranslationQualityForPath(
      "Test on a physical iPhone.",
      "在 iPhone 上测试。",
      mobilePath,
      "physical iPhone diagnostic",
    ),
    /required terminology "physical iPhone" -> "iPhone 真机\/实体 iPhone\/物理 iPhone"/,
  );
  assert.throws(
    () => validateTranslationQualityForPath(
      "Open the deep-link through Universal Links.",
      "通过通用链接打开深层链接。",
      mobilePath,
      "translated Universal Links",
    ),
    /technical name "Universal Links" count decreased/,
  );

  const minimalPairs = [
    ["The museum catalogs physical objects.", "博物馆对实体物件进行编目。", mobilePath],
    ["The production flavor of the soup is smoky.", "这款汤的量产口味带有烟熏味。", mobilePath],
    ["Profile builds trust over time.", "个人简介会逐渐建立信任。", mobilePath],
    ["Release builds pressure slowly.", "缓慢释放会逐渐形成压力。", mobilePath],
    ["The singer is signing posters.", "歌手正在给海报签名。", mobilePath],
    ["The essay uses deep-link as a metaphor.", "这篇文章用深层关联作比喻。", "writing-guide.md"],
    ["Read this screen-reader phrase as ordinary quoted text.", "将这段带连字符的短语当作普通引文阅读。", "writing-guide.md"],
  ];
  for (const [sourceText, translation, relativePath] of minimalPairs) {
    assert.doesNotThrow(() => validateTranslationQualityForPath(
      sourceText,
      translation,
      relativePath,
      "mobile terminology minimal pair",
    ));
  }
});

test("accepts professional checked-in repository wording without treating hotel check-in as Git", () => {
  const sourceText = "Use the checked-in fixture.";
  const acceptedTranslations = [
    "使用已提交到代码仓库的测试夹具。",
    "使用已纳入版本控制的测试夹具。",
    "使用随代码仓库提供的测试夹具。",
    "使用已检入代码仓库的测试夹具。",
  ];
  for (const acceptedTranslation of acceptedTranslations) {
    assert.doesNotThrow(() => validateTranslationQuality(
      sourceText,
      acceptedTranslation,
      "checked-in repository fixture",
      "developer-guide.md",
    ));
    assert.equal(
      normalizeTranslationTerminology(
        sourceText,
        acceptedTranslation,
        "checked-in repository fixture",
        "developer-guide.md",
      ),
      acceptedTranslation,
    );
  }

  const hotelSource = "The guest checked in at the hotel.";
  const hotelTranslation = "访客已在酒店办理入住。";
  assert.doesNotThrow(() => validateTranslationQuality(
    hotelSource,
    hotelTranslation,
    "hotel check-in",
    "developer-guide.md",
  ));
  assert.equal(
    normalizeTranslationTerminology(
      hotelSource,
      hotelTranslation,
      "hotel check-in",
      "developer-guide.md",
    ),
    hotelTranslation,
  );
});

test("preserves Library exactly and treats ordinary UI-label words contextually", () => {
  assert.throws(
    () => validateTranslationQuality("Open Library.", "打开个人论文库。", "fixture"),
    /Pakperk UI label "Library" count decreased/,
  );
  assert.throws(
    () => validateTranslationQuality("Open the Read tab.", "打开阅读标签页。", "fixture"),
    /Pakperk UI label "Read" count decreased/,
  );
  assert.doesNotThrow(() => validateTranslationQuality(
    "You can read the introduction and search for details.",
    "您可以阅读简介并搜索详细信息。",
    "fixture",
  ));
});

test("policy digest is deterministic and covers the effective validator implementation", () => {
  const first = translationPolicyDigest("adr/0008-document-ingestion-adapter.md");
  const second = translationPolicyDigest("adr/0008-document-ingestion-adapter.md");
  assert.match(first, /^[a-f0-9]{64}$/);
  assert.equal(first, second);
  assert.notEqual(first, translationPolicyDigest("user-guide.md"));
  assert.match(translationSystemPrompt("adr/0008-document-ingestion-adapter.md"), /container image=容器镜像/);
});
