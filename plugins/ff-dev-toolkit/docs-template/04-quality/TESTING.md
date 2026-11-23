---
title: "TESTING"
version: "1.7.0"
status: "draft"
owner: "@your-github-handle"
created: "YYYY-MM-DD"
updated: "2026-11-23"
changeImpact: "medium"
---

# TESTING.md - テスト戦略ガイド

> **テンプレート直接利用**: `${CLAUDE_PLUGIN_ROOT}` がない環境では、この変数をシェルで展開しません。本文でプラグイン配下のテンプレートを参照する箇所は、同じ相対パスを [公開テンプレート配布元](https://github.com/feel-flow/ff-dev-toolkit/tree/HEAD/plugins/ff-dev-toolkit/docs-template) から参照・取得してください。利用する配布版に合わせたタグのファイルを選び、ローカルにある同名ファイルを無条件で上書きしないでください。

## 1. テスト戦略概要

### テストピラミッド

```
         /\
        /E2E\        (10%) - エンドツーエンドテスト
       /------\
      /統合テスト\    (20%) - 結合テスト
     /----------\
    /ユニットテスト\  (70%) - 単体テスト
   /--------------\
```

### テスト比率の推奨値（テスト投資の配分）

テストスイート全体に対する**件数・工数の目安比率**（テストピラミッドに整合）。コードカバレッジ目標（次表）とは別概念である。

| テスト種別     | 推奨比率 | 役割の目安                                           |
| -------------- | -------- | ---------------------------------------------------- |
| ユニットテスト | **70%**  | ドメインロジック・ユーティリティの高速フィードバック |
| 統合テスト     | **20%**  | DB・メッセージ・外部API境界を含む結合の検証          |
| E2Eテスト      | **10%**  | クリティカルなユーザージャーニー・契約に近い経路     |

比率はプロジェクトの性質（レガシー比率、リリース頻度）で調整してよいが、E2Eのみに偏重しないこと。品質ゲート全体の枠組みは `docs/04-quality/GUARDRAILS_THREE_LAYERS.md`（初期セット外。相互に参照する `SECURITY_REVIEW_CHECKLIST.md` と一緒に、必要になった時点で `${CLAUDE_PLUGIN_ROOT}/docs-template/04-quality/` の同一相対パスからコピーする）を参照。

### カバレッジ目標

重要な業務、主要動作、失敗時の影響から検証対象を決める。件数比率や一律80%を合格条件にしない。数値目標が有効な場合は、対象範囲・指標・例外・理由をユーザーと合意する。未採用なら「数値目標なし」と記録し、完成条件に対応する検証を示す。

| 対象       | 推奨する判断                                   |
| ---------- | ---------------------------------------------- |
| 業務ルール | 正常系・境界・失敗が完成条件を満たすか         |
| 外部連携   | 契約・認証・データ・通信失敗への対応が妥当か   |
| 利用経路   | 主要な操作と利用者に影響する失敗を確認できるか |

## 2. ユニットテスト

### テスト構造（AAA Pattern）

```typescript
describe("UserService", () => {
  let service: UserService;
  let mockRepository: jest.Mocked<IUserRepository>;

  beforeEach(() => {
    // Arrange: テスト準備
    mockRepository = createMock<IUserRepository>();
    service = new UserService(mockRepository);
  });

  describe("createUser", () => {
    it("should create user successfully with valid data", async () => {
      // Arrange
      const userData = {
        email: "test@example.com",
        name: "Test User",
      };
      const expectedUser = { id: "123", ...userData };
      mockRepository.save.mockResolvedValue(expectedUser);

      // Act
      const result = await service.createUser(userData);

      // Assert
      expect(result).toEqual(expectedUser);
      expect(mockRepository.save).toHaveBeenCalledWith(
        expect.objectContaining(userData),
      );
    });

    it("should throw ValidationError for invalid email", async () => {
      // Arrange
      const invalidData = {
        email: "invalid-email",
        name: "Test User",
      };

      // Act & Assert
      await expect(service.createUser(invalidData)).rejects.toThrow(
        ValidationError,
      );
      expect(mockRepository.save).not.toHaveBeenCalled();
    });
  });
});
```

### モックとスタブ

```typescript
// モック作成ヘルパー
function createMock<T>(partial?: Partial<T>): jest.Mocked<T> {
  return {
    ...partial,
  } as jest.Mocked<T>;
}

// データビルダーパターン
class UserBuilder {
  private user: Partial<User> = {
    id: "123",
    email: "default@example.com",
    name: "Default User",
  };

  withEmail(email: string): this {
    this.user.email = email;
    return this;
  }

  withName(name: string): this {
    this.user.name = name;
    return this;
  }

  build(): User {
    return this.user as User;
  }
}

// 使用例
const user = new UserBuilder().withEmail("custom@example.com").build();
```

## 3. 統合テスト

### API統合テスト

```typescript
describe("User API Integration", () => {
  let app: Application;
  let db: Database;

  beforeAll(async () => {
    // テスト用データベース接続
    db = await createTestDatabase();
    app = await createApplication(db);
  });

  afterAll(async () => {
    await db.close();
    await app.close();
  });

  beforeEach(async () => {
    // データベースクリーンアップ
    await db.truncate(["users", "orders"]);
  });

  describe("POST /api/users", () => {
    it("should create user and return 201", async () => {
      const userData = {
        email: "test@example.com",
        password: "SecurePass123!",
        name: "Test User",
      };

      const response = await request(app)
        .post("/api/users")
        .send(userData)
        .expect(201);

      expect(response.body).toMatchObject({
        id: expect.any(String),
        email: userData.email,
        name: userData.name,
      });

      // データベース検証
      const user = await db.query("SELECT * FROM users WHERE email = $1", [
        userData.email,
      ]);
      expect(user).toBeDefined();
    });

    it("should return 409 for duplicate email", async () => {
      // 既存ユーザー作成
      await db.query("INSERT INTO users (email, name) VALUES ($1, $2)", [
        "existing@example.com",
        "Existing User",
      ]);

      const response = await request(app)
        .post("/api/users")
        .send({
          email: "existing@example.com",
          password: "Password123!",
          name: "New User",
        })
        .expect(409);

      expect(response.body.error.code).toBe("DUPLICATE_EMAIL");
    });
  });
});
```

### データベース統合テスト

```typescript
describe("UserRepository Integration", () => {
  let repository: UserRepository;
  let db: Database;

  beforeAll(async () => {
    db = await createTestDatabase();
    repository = new UserRepository(db);
  });

  describe("findByEmail", () => {
    it("should find user by email", async () => {
      // テストデータ準備
      await db.query(
        "INSERT INTO users (id, email, name) VALUES ($1, $2, $3)",
        ["123", "test@example.com", "Test User"],
      );

      const user = await repository.findByEmail("test@example.com");

      expect(user).toMatchObject({
        id: "123",
        email: "test@example.com",
        name: "Test User",
      });
    });

    it("should return null for non-existent email", async () => {
      const user = await repository.findByEmail("notfound@example.com");
      expect(user).toBeNull();
    });
  });
});
```

### 外部サービス統合テスト（モック注入）

決済・メール等の外部サービス（`docs/03-implementation/INTEGRATIONS.md`）は、DI コンテナでモック実装に差し替えて結合を検証する。

```typescript
// モックサービス
class MockPaymentService implements IPaymentService {
  failure?: AppError;

  async createPaymentIntent(amount: number): Promise<PaymentIntent> {
    if (this.failure) throw this.failure;
    return {
      id: "pi_test_123",
      amount,
      status: "succeeded",
    };
  }
}

// 統合テスト
describe("Payment Integration", () => {
  let app: Application;
  let payment: MockPaymentService;

  beforeEach(async () => {
    // NODE_ENV に依存せず、テストでは常に新しいモックを注入する
    payment = new MockPaymentService();
    container.register("PaymentService", { useValue: payment });

    app = await createApp();
  });

  it("should process payment successfully", async () => {
    const response = await request(app)
      .post("/payments")
      .send({
        amount: 1000,
        currency: "usd",
      })
      .expect(200);

    expect(response.body).toHaveProperty("paymentIntentId");
  });

  it("should report payment failure without returning success", async () => {
    payment.failure = new UpstreamError("Payment provider unavailable");
    // API は AppError.statusCode を返す契約。実プロジェクトのレスポンス契約に合わせる
    const response = await request(app)
      .post("/payments")
      .send({ amount: 1000, currency: "usd" })
      .expect(502);

    expect(response.body).not.toHaveProperty("paymentIntentId");
  });
});
```

## 4. E2Eテスト

### Playwright E2Eテスト

```typescript
import { test, expect } from "@playwright/test";

test.describe("User Registration Flow", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
  });

  test("should complete registration successfully", async ({ page }) => {
    // ナビゲーション
    await page.click("text=Sign Up");

    // フォーム入力
    await page.fill('input[name="email"]', "newuser@example.com");
    await page.fill('input[name="password"]', "SecurePass123!");
    await page.fill('input[name="confirmPassword"]', "SecurePass123!");
    await page.fill('input[name="name"]', "New User");

    // 利用規約に同意
    await page.check('input[name="terms"]');

    // 送信
    await page.click('button[type="submit"]');

    // 成功確認
    await expect(page).toHaveURL("/dashboard");
    await expect(page.locator("h1")).toContainText("Welcome, New User");
  });

  test("should show validation errors", async ({ page }) => {
    await page.click("text=Sign Up");

    // 無効なメールアドレス
    await page.fill('input[name="email"]', "invalid-email");
    await page.fill('input[name="password"]', "123"); // 弱いパスワード

    await page.click('button[type="submit"]');

    // エラーメッセージ確認
    await expect(page.locator(".error-email")).toContainText(
      "Valid email required",
    );
    await expect(page.locator(".error-password")).toContainText(
      "Password must be at least 8 characters",
    );
  });
});
```

### API E2Eテスト

```typescript
describe("Order Processing E2E", () => {
  let apiClient: ApiClient;
  let testUser: User;

  beforeAll(async () => {
    apiClient = new ApiClient(process.env.TEST_API_URL);

    // テストユーザー作成
    testUser = await apiClient.createUser({
      email: `test-${Date.now()}@example.com`,
      password: "TestPass123!",
    });

    await apiClient.authenticate(testUser.email, "TestPass123!");
  });

  test("complete order flow", async () => {
    // 1. 商品検索
    const products = await apiClient.searchProducts("laptop");
    expect(products.length).toBeGreaterThan(0);

    // 2. カートに追加
    const cart = await apiClient.addToCart(products[0].id, 1);
    expect(cart.items).toHaveLength(1);

    // 3. チェックアウト
    const order = await apiClient.checkout({
      cartId: cart.id,
      paymentMethod: "test-card",
      shippingAddress: {
        street: "123 Test St",
        city: "Test City",
        postalCode: "12345",
      },
    });

    expect(order.status).toBe("confirmed");
    expect(order.items).toHaveLength(1);

    // 4. 注文確認
    const fetchedOrder = await apiClient.getOrder(order.id);
    expect(fetchedOrder.id).toBe(order.id);
  });
});
```

## 5. パフォーマンステスト

### 負荷テスト（k6）

```javascript
import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  stages: [
    { duration: "2m", target: 100 }, // ランプアップ
    { duration: "5m", target: 100 }, // 維持
    { duration: "2m", target: 0 }, // ランプダウン
  ],
  thresholds: {
    http_req_duration: ["p(95)<500"], // 95%が500ms以内
    http_req_failed: ["rate<0.1"], // エラー率10%未満
  },
};

export default function () {
  const response = http.get("https://api.example.com/users");

  check(response, {
    "status is 200": (r) => r.status === 200,
    "response time < 500ms": (r) => r.timings.duration < 500,
  });

  sleep(1);
}
```

### ベンチマークテスト

```typescript
describe("Performance Benchmarks", () => {
  test("should process 1000 records within 1 second", async () => {
    const records = generateTestRecords(1000);

    const startTime = performance.now();
    await processor.processRecords(records);
    const endTime = performance.now();

    const duration = endTime - startTime;
    expect(duration).toBeLessThan(1000); // 1秒以内
  });

  test("memory usage should not exceed 100MB", async () => {
    const initialMemory = process.memoryUsage().heapUsed;

    await processor.processLargeDataset();

    const finalMemory = process.memoryUsage().heapUsed;
    const memoryIncrease = (finalMemory - initialMemory) / 1024 / 1024;

    expect(memoryIncrease).toBeLessThan(100); // 100MB以内
  });
});
```

## 6. セキュリティテスト

### 脆弱性テスト

```typescript
describe("Security Tests", () => {
  describe("SQL Injection Prevention", () => {
    test("should sanitize malicious SQL input", async () => {
      const maliciousInput = "'; DROP TABLE users; --";

      const response = await request(app)
        .get(`/api/users/search?q=${encodeURIComponent(maliciousInput)}`)
        .expect(200);

      // テーブルが削除されていないことを確認
      const tableExists = await db.query(
        "SELECT EXISTS (SELECT FROM pg_tables WHERE tablename = 'users')",
      );
      expect(tableExists.rows[0].exists).toBe(true);
    });
  });

  describe("XSS Prevention", () => {
    test("should escape HTML in user input", async () => {
      const xssPayload = '<script>alert("XSS")</script>';

      const response = await request(app)
        .post("/api/comments")
        .send({ content: xssPayload })
        .expect(201);

      expect(response.body.content).toBe(
        '&lt;script&gt;alert("XSS")&lt;/script&gt;',
      );
    });
  });

  describe("Authentication", () => {
    test("should prevent brute force attacks", async () => {
      const attempts = [];

      // 10回の失敗試行
      for (let i = 0; i < 10; i++) {
        attempts.push(
          request(app).post("/api/auth/login").send({
            email: "user@example.com",
            password: "wrong-password",
          }),
        );
      }

      const responses = await Promise.all(attempts);
      const lastResponse = responses[responses.length - 1];

      expect(lastResponse.status).toBe(429); // Too Many Requests
      expect(lastResponse.body.error.code).toBe("RATE_LIMIT_EXCEEDED");
    });
  });
});
```

## 7. テストデータ管理

### フィクスチャ

```typescript
// fixtures/users.ts
export const fixtures = {
  validUser: {
    id: "123",
    email: "john@example.com",
    name: "John Doe",
    role: "user",
    createdAt: new Date("2024-01-01"),
  },

  adminUser: {
    id: "456",
    email: "admin@example.com",
    name: "Admin User",
    role: "admin",
    createdAt: new Date("2024-01-01"),
  },
};

// テストでの使用
import { fixtures } from "./fixtures/users";

test("should authorize admin user", () => {
  const result = authorize(fixtures.adminUser, "admin:read");
  expect(result).toBe(true);
});
```

### シードデータ

```typescript
// seed.ts
export async function seedTestData(db: Database) {
  // ユーザー作成
  const users = await db.insert("users", [
    { email: "user1@test.com", name: "User 1" },
    { email: "user2@test.com", name: "User 2" },
  ]);

  // 関連データ作成
  await db.insert("orders", [
    { userId: users[0].id, total: 100 },
    { userId: users[1].id, total: 200 },
  ]);
}

// テストでの使用
beforeEach(async () => {
  await db.truncateAll();
  await seedTestData(db);
});
```

## 8. テスト自動化

### CI/CDパイプライン

```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_PASSWORD: testpass
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: "24"
          cache: "npm"

      - name: Install dependencies
        run: npm ci

      - name: Run linter
        run: npm run lint

      - name: Run unit tests
        run: npm run test:unit

      - name: Run integration tests
        run: npm run test:integration
        env:
          DATABASE_URL: postgresql://postgres:testpass@localhost:5432/test

      - name: Run E2E tests
        run: npm run test:e2e

      - name: Upload coverage
        # if: always() が無いと、テストが失敗した回のカバレッジ・レポートが
        # ランナーから出てこない。原因調査に必要なのはまさに失敗した回なので、
        # 赤いときこそ回収する
        if: always()
        uses: codecov/codecov-action@v3
        with:
          file: ./coverage/lcov.info
```

## 9. テストレポート

### カバレッジレポート設定

```javascript
// jest.config.js
module.exports = {
  collectCoverage: true,
  coverageDirectory: "coverage",
  coverageReporters: ["text", "lcov", "html"],
  // coverageThreshold は数値目標の採用を合意した場合だけ追加する。
  collectCoverageFrom: [
    "src/**/*.{ts,tsx}",
    "!src/**/*.spec.{ts,tsx}",
    "!src/**/*.interface.ts",
    "!src/**/index.ts",
  ],
};
```

## 10. テストベストプラクティス

### テスト命名規則

```typescript
// ✅ 良い例: 具体的で理解しやすい
it("should return 404 when user does not exist", () => {});
it("should validate email format before saving", () => {});
it("should retry 3 times on network failure", () => {});

// ❌ 悪い例: 曖昧
it("works", () => {});
it("test user", () => {});
it("error case", () => {});
```

### テストの独立性

```typescript
// ✅ 良い例: 各テストが独立
describe("UserService", () => {
  let service: UserService;

  beforeEach(() => {
    // 各テストで新しいインスタンス
    service = new UserService();
  });

  test("test1", () => {
    // このテストは他のテストに依存しない
  });
});

// ❌ 悪い例: テスト間で状態を共有
let globalUser;
test("create user", () => {
  globalUser = createUser();
});
test("update user", () => {
  updateUser(globalUser); // 前のテストに依存
});
```

### 変異注入の適用確認

変異注入で検出力を測るときは、**変異が実際に適用されたことを機械的に確認してから**結果を読む。適用に失敗しても「テストが緑」という出力は検出失敗時と同じため、確認を挟まないと「針が効かない」という逆の結論を引き出しうる。

- 変異はシェル補間を通す形（`python3 -c "..."` のようなダブルクォート内スクリプト）で書かない。スクリプトがシェルの引用処理と Python の文字列リテラル解釈の 2 層を通るため、エスケープや引用の入れ子で「書いたつもりの文字列」と「実際に比較される文字列」がずれやすい（例: 対象ファイル内の literal な 2 文字 `\n` に対し、Python は `"needle\n"` を needle + 改行として解釈するので一致しない）。クォート済みヒアドキュメント（`<<'PY'`）でファイルへ書き出してから実行する
- 変異スクリプトは対象文字列の出現回数を検査し、適用に失敗したら非 0 で即座に落とす（Python の `assert` 文は `-O` 実行で消えるため、明示の条件分岐で `SystemExit` を投げる）。呼び出し側も `|| exit 1` で受け、適用が確認できないまま後続のテスト実行へ進まない。不一致は traceback として loud に落ちても、呼び出し側が非 0 を無視すると最終出力は「全件 pass」に見える
- 結果の報告には「適用の成否」と「検査結果」を必ず 2 つ並べて書く。「変異が当たらなかった」と「変異が検出されなかった」を出力から区別できる形にする
- 変異の復元は **sed 往復**（適用と逆適用を対で書く）か、**変異前にコミットしてから** `git checkout` する。未コミットの変更が残る状態での `git checkout -- <file>` は、変異と一緒に本修正まで巻き戻す（PR #781 の実測。以後 sed 往復へ切替えた同セッションの変異試験 5 回では再発していない）

```bash
# ❌ 悪い例: シェル補間経由 — 引用の入れ子と文字列リテラル解釈の層がずれても、
# 適用を検査しない形では外から見えない
python3 -c "s = open('verify.sh').read(); assert 'needle\n' in s"

# ✅ 良い例: クォート済みヒアドキュメントでファイル化する — シェル側の解釈層
# （引用の入れ子・$ 展開）を排除し、実行したスクリプトを目視・再実行できる形で残す
MUT="$(mktemp "${TMPDIR:-/tmp}/mutate.XXXXXX")"
cat <<'PY' > "$MUT"
import pathlib
p = pathlib.Path("verify.sh")
s = p.read_text()
# 対象が literal な backslash 列を含む場合は raw 文字列（r"needle\n"）を使う
if s.count("needle\n") != 1:
    raise SystemExit("mutation target not found")
p.write_text(s.replace("needle\n", "mutated\n"))
PY
python3 "$MUT" || exit 1  # 適用に失敗したら検査へ進まない
echo "変異適用: OK"       # 報告には検査結果と並べてこの成否を併記する（復元は上記の sed 往復 / 事前コミット参照）
```

### 変異注入の結果の読み方と書き戻し先

前節は「変異が当たったか」を確かめる作法で、ここは**当てた結果をどう読み、どこへ残すか**である。
この 2 つが欠けると、検出力ゼロの検査が「緑だから守られている」と読まれたまま残る。

- **新しい検査を 1 つ書いたら、コミット前・その場で変異を当てる。** 後回しにすると、検出力の確認は
  書き手の記憶だけに頼ることになり、実行されない
- **変異は検査 1 つにつき 1 つの粒度で並べる。** まとめて複数箇所を壊すと、どの検査がどの不変条件を
  守っているか判別できない。同じ対象へ 2 つの変異を**同時に**当てるのも避ける — 赤が出ても
  どちらの変異の結果か帰属できない。復元を `git checkout` 系で行う場合はさらに、一方の復元が
  他方の変異ごと巻き戻す
- **赤転しなかった変異は、そのまま検査追加の TODO にする。** 変異を入れても緑のままなのは、その箇所を
  守る検査が存在しないことの**実測**であって、注入の失敗ではない（緑 = 守られているではなく、
  緑 = 誰も測っていない）。TODO を残したまま新設の検査をマージしない — その場で検査を足し、赤転を
  確認してから次の変異へ進む
- **どうしても赤にできない変異は、消さずに理由とともに残す。** 「他の層が吸収している」「その状態を
  注入する手段が環境依存になる」など、測れない理由まで書く。黙って落とすと、測れていない事実自体が
  失われる。赤にできない形は少なくとも 3 つある — **注入する手段が無い**（その状態を作れない）、
  **注入できたが振る舞いが変わらない**（同値な書き換え）、**別の層が吸収している**（前段の検査や
  既定の分岐が同じ結果へ倒す）。いずれも「検査が足りない」とは違うので、どれに当たるかまで書く。
  ただし**検査を足せば赤にできる変異は前項が優先する** — 理由を書けばマージしてよい、という
  抜け道にしない
- **結果は当該検査自身の先頭コメント（ヘッダ）へ書き戻す。** 変異ごとに「何をどう壊すと、どの検査が
  赤になるか」を 1 行で並べる。検査の隣に置くのは、検査を読む人と変異表を読む人が同じだからで、
  離れた場所に置いた表は検査の変更に追随しない

書き戻しの形（検査スクリプトの先頭コメント。`#` は例示で、コメント記法は検査を書いた言語のものへ
読み替える。JavaScript / TypeScript なら `//`）。**1 行 1 変異**で、赤になった検査を名指しする
（検査に識別子が無い形なら赤になった件数でよいが、変異と赤の対応が読み取れる粒度を保つ）:

```text
# 変異検出（<測った日>実測。変異は 1 件ずつ直列に当て、前後で対照を取る）:
#   <何をどう壊したか> → <赤になった検査の名前または番号> が赤。
#   <何をどう壊したか> → <赤になった検査の名前または番号> が赤。
#
#   赤転しなかった変異も記録する:
#   <何をどう壊したか> → 緑。<なぜ測れないのか>。
```

## 文書契約面を部分ゲートで覆う

入口規範（`CLAUDE.md` / `AGENTS.md`）・配布テンプレート・運用仕様などの**契約文書だけ**を変えた PR に、
無関係な実装テストを含む全件ゲートを掛けない。境界の正本は運用ガイド
`05-operations/deployment/workflow-principles.md` の「検証強度のリスク層別化（3 層モデル）」にある
Tier 2a（文書契約面）/ Tier 2b（実行基盤の契約面）で、本節は検証スイートへの組み込み方を示す。

検証スイート（`npm run ci:local` / `pnpm verify:gate` など）が持つものは 3 つである。

1. **2 種類の契約面の名簿**: 全件へ倒す実行基盤の契約面（ランナー自身・共有ライブラリ・hook 登録・
   共有依存・CI 定義・権限 / 安全境界）と、束を足して覆う文書契約面（入口規範・契約文書）を別の
   名簿として持つ。1 つの path を両方へ入れない。文書契約面へディレクトリを入れるときは、文書の
   拡張子で絞る — 配布物のディレクトリには実行コードや設定が同梱されていることがあり、それらは
   別の検査が読み込んで実行するので、文書ではなく実行基盤の契約面として全件へ倒す
2. **文書横断検査の束**: 文書契約面の変更で必ず選ぶ検査の名簿。入れる基準は「検査の入力が、名指しの
   ファイルではなく文書の集合である」こと（節参照の飛び先・入口どうしのパリティ・版と変更履歴の整合・
   文書 lint・公開対象の走査など）。変更パスを字面に持たないので、差分との交差だけでは選ばれない
3. **差分を覆った印の記録**: 選んだ検査が skip / 未実行 0 件で通った回だけ、PR の base の SHA を
   `scripts/record-gate-head.sh --gate <ゲートのラベル> --status partial --suites <通った検査> --covers-diff <base の 40 桁 SHA>` で記録する

判定の順は次のとおり。倒れる向きはすべて「多く回す」側に置く。

| 変更の中身 | 選ぶ検査 | 差分を覆った印 |
| --- | --- | --- |
| 実行基盤の契約面を 1 件でも含む（文書契約面と同時でも） | 全件 | 付けない |
| 文書契約面を含み、実行基盤の契約面を含まない | 差分と交差する検査 + 束の全検査 | 条件を満たせば付ける |
| どちらの契約面も含まない | 差分と交差する検査 | 条件を満たせば付ける |

- 束に名指しした検査が検証スイートの登録に 1 つでも無い回（改名・削除・重複・束が空）は、見つかった
  分だけで通さず全件へ倒す。束の名簿と登録の対応は、検証スイート自身のテストで固定する
- 実行基盤の契約面の判定は、変更一覧の全件を見終えてから確定する。文書契約面を先に見つけた時点で
  判定を打ち切ると、後ろに並んだ実行基盤の変更を文書側へ倒してしまう
- 印を付けるのは、選んだ検査が 1 件以上あり、すべて通過し、skip と未実行が 0 件の回だけである。
  環境の都合で束の検査が skip した回は、印を付けずに全件側へ倒す
- 検証スイートから起動しても**常に** skip する検査（リリースの直前にだけ明示起動する検査など）は、
  差分と交差しても選ぶ検査に入れない。選んでも何も検査せず、skip の混入で印が付かなくなる。
  全件でも回らない検査なので、外しても覆う範囲は変わらない。外す対象は名簿で名指しし、外した
  ことを出力へ残す。環境の都合で skip する検査は外さない

印を付けた記録は `finish.sh precheck` が読む。印が PR の base と一致すれば `DIFF_COVERED=yes` /
`RERUN_FULL_GATE=no` を返し、全件ゲートの再実行を求めない。base が進んで印と食い違った回・印の無い
部分実行は、PR の checks が全件成功している回を除き、従来どおり `RERUN_FULL_GATE=yes` になる。precheck は path を解釈しないので、**実行基盤の
契約面の変更へ印を付けないこと**は検証スイート側の責務である。

字面に現れない依存（検査が呼ぶスクリプトがさらに読む文書など）は束でも拾えないことがある。この
残差は定期全件ゲート（リリース前全件・定期 CI など）が拾う前提なので、定期全件の安全網を持たない
プロジェクトでは文書契約面も全件へ倒す。

## ゲート起動の終了コードを保持する

ff-dev-toolkit の終了コードガードは `run-all.sh` のほか、導入先が宣言したゲートも検査する。
宣言は **hook を起動するホストのプロセス環境**へ `FF_EXIT_CODE_GUARD_GATES` を export する。
Bash ツールの command 本文に代入を書くだけでは、実行前の hook の環境へ届かない。
設定後にホストを起動し、grok CLI では hook の展開も済ませる（発火するホストと設定方法は利用版の README を参照）。

```bash
export FF_EXIT_CODE_GUARD_GATES=$'npm run ci:local\npnpm validate:app\npnpm validate:all'
```

区切りは改行で、colon はコマンド名の一部として扱う。引用のない語の列を literal prefix として
照合し、前後の空白・空行は無視、語間の space / tab は同一視する。宣言には環境代入・wrapper を含めず、起動側からそれらを
剥がしてから照合し、後続の引数・リダイレクトは許容する。`ci:locality` のような名前の前方一致、
正規表現・glob・シェル展開・eval は行わない。引用した引数や変数で組み立てた起動は字面解析の対象外。
未設定・空・空白行だけなら、追加ゲートは無く従来どおり。宣言を使わない他のコマンドへ対象を広げない。

宣言したゲートで `; echo "exit=$?"; tail log` のように終了すると、完了通知は末尾の診断の成否になるため
PreToolUse が停止する。ログを表示する場合も、直後に rc を保存し、最後に伝播させる。

```bash
npm run ci:local > log 2>&1; rc=$?; tail log; exit $rc
```

同じ環境変数は静的な `exit_code_scan` / `exit_code_scan_bash_blocks` にも効く。
保存時の `guard-shell-save`（Write / Edit）も同じ共有検出器を使うため、宣言したゲートの新しい危険形を検査する。
本節の設定例と検査はローカルの hook 入力 fixture で確認するもので、リリースの受け取りや
導入先の実セッションでの発火を証明しない。配布版の更新後は導入先でも上の危険な起動形が停止するか確認する。

## Changelog

### [1.7.0] - 2026-11-23

#### 追加

- 「文書契約面を部分ゲートで覆う」節を追加した。契約面を実行基盤と文書の 2 つの名簿に分け、文書契約面だけの変更は差分と交差する検査に文書横断検査の束を足して覆い、差分を覆った印の記録で全件ゲートの再実行を省く組み込み方と、全件へ倒す条件、常に skip する検査を選ぶ検査に入れない扱いを示した。

### [1.6.0] - 2026-10-22

#### 追加

- 導入先ゲートの改行区切り宣言、hook 環境への受け渡し、終了コードを保存・表示・伝播する形を追加した。

### [1.5.0] - 2026-10-17

#### 修正

- 外部サービス統合テストは環境値に依存せずモックを登録し、決済失敗時に成功を返さないケースを追加する

- 2026-09-08 追記: プラグイン変数がない直接利用でも取得できる公開配布元を明記（ai-spec-driven-development#525）。

### [1.4.0] - 2026-10-16

#### 追加

- §3 に「外部サービス統合テスト（モック注入）」節を追加（INTEGRATIONS.md の「統合テスト」節を移設。[ai-spec-driven-development#511](https://github.com/feel-flow/ai-spec-driven-development/issues/511)）。公開配布元で 1.3.0 として記録した追記を本版へ統合した。版番号は両系統の最大を超える値にした

### [1.3.1] - 2026-09-26

- GUARDRAILS_THREE_LAYERS.md のコピー案内を、相互に参照する SECURITY_REVIEW_CHECKLIST.md と一緒にコピーする形へ揃えた（MASTER.md の品質・セキュリティ節と同じコピー単位）。

### [1.3.0] - 2026-09-13

#### 追加

- §変異注入に「結果の読み方と書き戻し先」節を追加。当てた結果の読み方（検出できなかった変異の扱い）と、結果の残し先を明文化した。

### [1.2.0] - 2026-09-08

- ASDD 2.0: project-specific recommendations and explicitly agreed optional features (Issues #1372 / #1374).

### [1.1.1] - 2026-09-06

#### 変更

- 初期セット外（`GUARDRAILS_THREE_LAYERS.md`）への Markdown リンクを、コピー元付きの案内テキスト（inline code）に変更

### [1.1.0] - 2026-08-21

#### 追加

- §10 に「変異注入の適用確認」節を追加（ヒアドキュメント化・適用の出現回数検査と非 0 即停止・適用の成否と検査結果の併記）

### [1.0.0] - YYYY-MM-DD

#### 追加

- 初版作成

#### 変更

- テストピラミッドの推奨比率を70/20/10に更新し、「テスト比率の推奨値（テスト投資の配分）」節とガードレール文書への参照を追加
- ピラミッド図の英語ラベルを日本語（単体・結合・E2E）に統一
