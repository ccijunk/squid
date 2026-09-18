# 设计文档：client-first bump 伪造叶子证书补 Authority Key Identifier（AKI）

提交：`2621d68c3999784f6f9439a1874d0e0f1d381c58`
分支：`v7.7.2`（基线 `v7.7` + PR 2401 + 本次改动）
镜像：`swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.2`

## 1. 问题

线上 squid 7.7.1（client-first bump）签发的伪造叶子证书，扩展区只有
`subjectAltName`，缺 `AuthorityKeyIdentifier`（AKI）。严格 X.509 校验器会拒签：

| 校验方 | 报错 |
|---|---|
| Python 3.13+ / conda 26（`VERIFY_X509_STRICT`） | `Missing Authority Key Identifier` |
| `openssl verify -x509_strict` | error 85 |

代理功能本身对宽松客户端无影响，只有严格校验器失败——而这恰好是该代理背后
CI 任务使用的工具链。

## 2. 背景：client-first 与 server-first 的区别

### 2.1 一句话区别

- **server-first（服务端优先）**：Squid **先连 origin**，拿到真实服务器证书，再据此
  **模仿**着伪造一张给客户端。
- **client-first（客户端优先）**：Squid **先和客户端完成握手**（用自己 CA 现造一张
  证书），**之后**才连 origin。

### 2.2 握手时序

```
server-first                           client-first
──────────────────────────────         ──────────────────────────────
client ──ClientHello──▶ squid          client ──ClientHello──▶ squid
squid  ──连 origin + ClientHello──▶    squid  ──伪造证书（无 origin 可模仿）──▶
origin ──ServerHello + 真实证书──▶     client ──Finished──▶ squid
       ← 此时才拿到 mimicCert          squid  ──连 origin + ClientHello──▶
squid  ──伪造证书（逐字段模仿 origin）──▶ origin ──ServerHello + 真实证书──▶
client ──Finished──▶ squid
```

client-first 省掉了「等 origin 回来」这一轮，但代价是**伪造证书时手里没有任何 origin
信息**。

### 2.3 对照表

| | server-first | client-first |
|---|---|---|
| 连 origin 时机 | 客户端握手**之前** | 客户端握手**之后** |
| `properties.mimicCert` | **有**（origin 真实证书） | **无**（null） |
| 伪造证书的来源 | 逐字段模仿 origin | 只能用 CA + 目标域名合成 |
| 可模仿的扩展 | SAN / KU / EKU / BC / AKI 全部照抄 | 只有 SAN（+ 本补丁补的 AKI） |
| 能否据握手信息决策 | 不能 | 能（SNI 等） |
| 能否提前发现 origin 证书错误 | 能（伪造前就校验） | 不能（错误延后暴露） |
| 拦截式 SSL（透明代理） | 支持 | **不支持**（文档明确） |
| 延迟 | 多一轮 origin RTT | 少一轮 |

### 2.4 在现代 Squid 里它们是兼容别名

`client-first` / `server-first` 只是 `SslBump1` 上的向后兼容动作，新写法是 `bump`
按步骤区分：

- **`ssl_bump bump` 在 step1** → 等价 client-first：先建客户端连接，再连服务器
- **`ssl_bump bump` 在 step2/step3** → 等价 server-first：先连服务器，再用模仿证书
  对客户端

三个步骤的定义（[AtStepData.cc](file:///home/chenqi252/code/gitcode-ci/workspace-squid/self-squid/src/acl/AtStepData.cc#L24-L32)、
[cf.data.pre](file:///home/chenqi252/code/gitcode-ci/workspace-squid/self-squid/src/cf.data.pre#L1576-L1581)）：

| 步骤 | 时机 |
|---|---|
| `SslBump1` | 拿到 TCP 层与 HTTP CONNECT 信息之后 |
| `SslBump2` | 拿到**客户端** ClientHello 之后 |
| `SslBump3` | 拿到**服务端** ServerHello 之后 |

官方措辞见 [cf.data.pre](file:///home/chenqi252/code/gitcode-ci/workspace-squid/self-squid/src/cf.data.pre#L3262-L3276)：
client-first "does not allow Squid to mimic server SSL certificate and does not work
with intercepted SSL connections"；server-first "does not allow to make decisions
based on SSL handshake info"。

### 2.5 与本 bug 的关系

这正是根因所在：

```
client-first  →  properties.mimicCert == null
              →  mimicAuthorityKeyId() 开头 `if (!mimicCert.get() || ...) return false;` 短路
              →  伪造叶子完全没有 AKI
              →  Python 3.13+ / openssl -x509_strict 拒签
```

**server-first 不会有这个 bug**——它 `mimicCert` 非空，AKI 直接从 origin 证书照抄下来。

一句话总结：**server-first 靠「抄 origin」，client-first 只能靠「自己造」；AKI 恰好是
少数能自己造、且必须造的东西。**

## 3. 根因

[src/ssl/gadgets.cc](file:///home/chenqi252/code/gitcode-ci/workspace-squid/self-squid/src/ssl/gadgets.cc#L358-L381)
中 `mimicAuthorityKeyId()` 开头为：

```cpp
if (!mimicCert.get() || !issuerCert.get())
    return false;
```

client-first bump 不连 origin，没有可模仿的证书（`mimicCert` 为空），函数直接短路，
永远走不到写 AKI 的代码。调用侧同样无条件限制：`mimicExtensions()`（进而
`mimicAuthorityKeyId()`）只在 `if (properties.mimicCert.get())` 分支内被调用。

使修复成本极低的关键事实：`mimicAuthorityKeyId()` 的**值构造段完全不依赖
`mimicCert`**。AKI 的值取自 `issuerCert`——此处即 `properties.signWithX509`，
也就是我们自己的 `SquidCacheCA`，带 Subject Key Identifier（`78:AE:69:...`）。
只有**形状**（是否写 `keyid`，以及是否写 `issuer`+`serial`）由 origin 证书自身的
AKI 决定。

## 4. 方案选型

**选定（方案 A）**：当 `mimicCert` 缺失但 `issuerCert` 存在时，跳过形状模仿段，
强制 `addKeyId = true`，复用既有值构造段，用签发 CA 的 SKI 构造 AKI。

理由：最小 diff（约 10 行），不新增任何 ASN.1 代码，mimic 路径行为零变化，且产出的
正是严格校验器所要求的那个扩展。

**已否决方案：**

- *peek step2 采集 origin 的 AKI 以还原形状。* 被 `PINNED` 判死——额外的 origin
  往返与 client-first 的设计目标冲突。
- *对白名单域走 splice 而不 bump。* 会丢掉重写缓存，也丢掉该代理存在的意义
  （镜像重写）。

## 5. 改动内容

### 5.1 `mimicAuthorityKeyId()` —— 拆分短路

```cpp
if (!issuerCert.get())
    return false;

bool addKeyId = false, addIssuer = false;
if (mimicCert.get()) {
    // ... 保持原样：读取 origin AKI，设置 addKeyId / addIssuer，
    //     两者都不需要时 return false
} else {
    // client-first bump：无 origin 证书可模仿。
    addKeyId = true;
}
```

两条路径：

- `mimicCert` 存在 → 原代码**逐字节搬进** `if` 分支，语句、顺序、提前
  `return false` 全部不变。
- `mimicCert` 缺失但 `issuerCert` 存在 → 跳过形状段，置 `addKeyId = true`，
  落入共享的值构造段。
- `issuerCert` 缺失 → 仍然 `return false`（没有可用于构造 AKI 的来源）。

### 5.2 调用点 —— 无 mimicCert 时也能进入

```cpp
addedExtensions += mimicExtensions(cert, properties.mimicCert, properties.signWithX509);
} else if (mimicAuthorityKeyId(cert, properties.mimicCert, properties.signWithX509)) {
    ++addedExtensions;
}
```

`else if` 是唯一新增入口，仅在 `properties.mimicCert` 为空时执行；把 AKI 计入
`addedExtensions`，从而让既有的「有扩展 → 标记为 v3」逻辑
（`X509_set_version(cert, 2)`）照常触发。

### 5.3 版本号

`Dockerfile`：`ARG SQUID_VERSION=7.7.1` → `7.7.2`，使 `squid -v` 报出发布版本
而非 `7.7-VCS`。

## 6. 不变式（硬验收）

1. **mimic 路径逐字节一致。** 只要 `mimicCert` 存在，产出的 DER 必须与补丁前完全
   相同。通过把原代码整体搬入分支、不做任何修改来保证。
2. **数据/重写路径零改动。** AKI 只加在证书**伪造**层，请求路由、缓存、URL 重写
   均不涉及。
3. **只新增一个扩展。** client-first 叶子只补 `AuthorityKeyIdentifier`；缺
   KU/EKU/BC/SKI **不补**——A/B 实测证明严格校验器不会因这些而拒签。
4. **签发者不变。** AKI 取自 `signWithX509`，叶子仍由同一个 CA 签发，现有信任锚
   固定策略继续有效。

## 7. 验证

本地容器，镜像 `v7.7.2`：

- 经代理抓取的伪造叶子出现 `Authority Key Identifier: keyid:78:AE:69:...`，
  与 `SquidCacheCA` 的 Subject Key Identifier 一致。
- `openssl verify -x509_strict -CAfile squid-ca.pem leaf.pem` → OK。
- Python 3.14.7 在 `VERIFY_X509_STRICT` 下经代理完成真实 TLS 握手 → PASS
  （补丁前为 FAIL）。

部署侧三道闸（在 gy-006 上执行）：

1. **证书闸** —— 用 `openssl s_client -proxy ...` 连任一被 bump 域（白名单外的
   https 域），断言 AKI 等于 CA SKI，且 `-x509_strict` verify 返回 OK。
2. **矩阵闸** —— 复跑 AKItest 套件；python 3.13 / 3.14 default 由 FAIL 翻 PASS，
   其余 case 全绿无回归。
3. **业务闸** —— tool-11-conda（no-mirror-test）通过；tool-04-go 抽查确认重写链路
   无回归（access.log 仍见 `goproxy.cn/...`）。

## 8. 构建与发布

```bash
docker buildx build -f Dockerfile \
  -t swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.2 \
  --load .
docker push swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.2
```

镜像为 rootful：容器进程以 root 运行，squid 守护进程以 uid/gid 31 运行
（与 Alpine 的 `squid` 一致），因此已有 PVC 缓存内容可直接复用。

## 9. 回滚

把部署的镜像 tag 换回 `v7.7.1` 即可。补丁无持久状态：`sslcrtd` 生成的证书随 pod
重建自然刷新，旧的（无 AKI）行为立即恢复。

## 10. 红线

- 不动 mimic 路径语义。
- 不动数据/重写路径。
- 不改 chart 架构与 release 名。
- 不碰 `cache_peer`。
