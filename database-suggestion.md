# Database hosting suggestions — Neulight OMS Archive

**Purpose:** Help the client choose where permanent historical data will live.  
**Audience:** Non-technical decision makers (can share as-is or paraphrase).  
**Context:** Client does **not** have a database server yet. The Archive Layer 2 project needs a place to store history long-term (orders, wallet, inventory movements, etc.). Google Sheets stays as the temporary archive; this database becomes the permanent one.

**Last updated:** 2026-09-19  
**Prices:** Approximate USD, starting sizes, mid‑2026 public list prices. Always re-check the provider’s pricing page before signing up. Storage, backups, and traffic can add a little on top.

---



## What you actually need (plain English)


| Need                                  | Why                                                                                                        |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| A **managed** database                | Someone else runs backups, updates, and the server. You don’t maintain a PC in the office 24/7.            |
| Enough space for **years of history** | Current dumps are tens of megabytes. Even a small cloud plan (10–20+ GB) is plenty to start.               |
| Secure login                          | Only the archive tool (and people you approve) can connect. Not public to the internet without a password. |
| Room to grow                          | You can upgrade later if reports get heavy.                                                                |


You do **not** need the biggest enterprise plan on day one.

**MySQL vs PostgreSQL:** The written project spec was drafted for **MySQL**. MySQL options below match that document most closely. PostgreSQL (option 4) is still a solid database — the build would use Postgres types instead of MySQL types. Either can store the archive well.

---



## Quick comparison


|                        | Option 1 — DigitalOcean MySQL | Option 2 — Google Cloud SQL (MySQL) | Option 3 — Amazon RDS (MySQL)    | Option 4 — Supabase (PostgreSQL)         |
| ---------------------- | ----------------------------- | ----------------------------------- | -------------------------------- | ---------------------------------------- |
| **Best for**           | Simple bill, easy start       | Already in Google / Sheets world    | Already on AWS / want big-cloud  | Easiest web dashboard                    |
| **Database type**      | MySQL (matches spec)          | MySQL (matches spec)                | MySQL (matches spec)             | PostgreSQL (different, still fine)       |
| **Rough start cost**   | ~$15–30 / month               | ~$15–40 / month                     | ~$20–50 / month                  | Free trial / then ~$25+ / month          |
| **Ease for non-tech**  | High                          | Medium                              | Lower                            | Highest                                  |
| **Our pick if unsure** | **Strong default**            | Good if you live in Google          | Only if AWS is already your home | Good if you want to browse data yourself |


---



## Option 1 — DigitalOcean Managed MySQL

**What it is:** DigitalOcean hosts a MySQL database for you. Flat monthly price. Popular with smaller teams who want “set it up and don’t think about servers.”

### Pros

- Price is **predictable** (clear monthly plans).
- True **MySQL** — closest match to the project specification.
- Setup is relatively simple; less jargon than AWS/Google.
- Automatic backups on managed plans.
- Easy to **upgrade** RAM/storage later without rebuilding everything.



### Cons

- Not the same company as Google Sheets (two vendors: Sheets + DigitalOcean).
- Fewer “enterprise” compliance checkboxes than AWS/Google (fine for most SME archives).
- You still need someone technical for first-time setup and secure passwords.



### Costing (ballpark)


| Plan idea                               | Rough monthly                        |
| --------------------------------------- | ------------------------------------ |
| Small start (1 GB RAM, ~10 GB disk)     | **~$15**                             |
| Comfortable small production (2 GB RAM) | **~$30**                             |
| High availability (extra standby copy)  | roughly **2×** the single-node price |


Extra storage is billed separately (on the order of ~$0.20 per GB / month).  
**Likely first-year range for Neulight archive:** about **$15–40 / month** unless you add HA or heavy analytics.

### Other important info

- Good **default recommendation** if the client has no cloud preference.
- Region: pick a region close to the Philippines or Singapore when available (lower lag, clearer data residency story).
- Billing is usually by card; account is in the client’s name (they own the data).

---



## Option 2 — Google Cloud SQL (MySQL)

**What it is:** Google’s managed MySQL, in the same broad ecosystem as Google Sheets / Google Workspace.

### Pros

- **MySQL** — matches the written spec.
- Natural fit if the company already uses **Google Workspace** and Sheets.
- Strong backups, monitoring, and Google-grade infrastructure.
- Can grow into a larger Google Cloud setup later (reports, BigQuery, etc.) if needed.



### Cons

- Google Cloud billing and console feel **more complex** for non-technical owners.
- Monthly cost can be **harder to predict** (instance + storage + backups + network billed separately).
- Smallest “shared” instances are cheap but not meant for heavy production load — you may step up sooner.



### Costing (ballpark)


| Plan idea                              | Rough monthly                           |
| -------------------------------------- | --------------------------------------- |
| Tiny shared instance (dev / light use) | **~$8–15** compute + storage            |
| Small practical production             | **~$25–50** all-in is a common ballpark |
| High availability (second copy)        | roughly **2×** compute                  |


Storage and backups are extra (SSD storage is typically a few dollars for tens of GB).  
**Likely first-year range:** about **$20–60 / month** for a small archive, depending on size and region (Asia regions often a bit higher than US).

### Other important info

- Best if the client already has (or wants) a **Google Cloud** account and is comfortable with Google billing.
- Useful if future tools will stay “in Google.”
- Requires careful IAM / password setup so the archive tool can connect securely.

---



## Option 3 — Amazon RDS for MySQL (AWS)

**What it is:** Amazon’s managed MySQL (RDS). Industry standard for companies already on AWS.

### Pros

- **MySQL** — matches the spec.
- Extremely common in enterprise; lots of talent and documentation.
- Excellent reliability options (Multi-AZ = standby in another data center).
- Easy path later to more AWS tools (reporting, warehouses) if the company goes that route.



### Cons

- **Most complex** of the four for a non-technical owner (AWS console, VPC, security groups).
- Bills are famous for being **hard to read**; easy to under- or over-estimate.
- Overkill if you only need one quiet historical archive and nothing else on AWS.



### Costing (ballpark)


| Plan idea                                    | Rough monthly       |
| -------------------------------------------- | ------------------- |
| Smallest burstable instance + ~20 GB storage | **~$15–25**         |
| Small production Single-AZ                   | **~$25–50**         |
| Production with Multi-AZ (extra standby)     | often **~$75–150+** |


**Likely first-year range if kept small:** about **$25–60 / month**. Costs jump if Multi-AZ or larger machines are chosen.

### Other important info

- Recommend **only if** the client already uses AWS, has an AWS partner, or expects to grow into AWS.
- Someone technical should own the account setup (networking and security).
- Not the friendliest “first database” for a Sheets-first OMS team.

---



## Option 4 — Supabase (PostgreSQL)

**What it is:** A hosted **PostgreSQL** database with a friendly website: tables, SQL editor, and dashboards in the browser. Not MySQL, but still a proper relational database for historical data.

### Pros

- **Easiest to explore** for non-technical people (open the site, see tables).
- Fast to create a project; good free tier for trials.
- Automatic backups on paid plans; modern tooling.
- Can still power reports and archive history well.



### Cons

- **Not MySQL** — the written technical spec assumed MySQL. The archive engine would be built for Postgres instead (same idea, different dialect). Slightly different types and tools.
- Free projects can **pause** if unused; production needs a paid plan.
- Extra Supabase features (auth, storage) are unused for this archive — you mainly want the database.



### Costing (ballpark)


| Plan idea                              | Rough monthly                                 |
| -------------------------------------- | --------------------------------------------- |
| Free (trial / proof of concept only)   | **$0** (limits; can pause)                    |
| Pro (normal production starting point) | **from ~$25** (includes small compute credit) |
| Larger compute / more storage          | **$25–80+** depending on size                 |


**Likely first-year range:** about **$25–50 / month** for a small always-on archive.

### Other important info

- Choose this if the client values **“I can log in and look at the data myself”** more than matching the MySQL wording in the spec.
- Confirm once with the developer that Postgres is acceptable before locking the build.
- Still managed and secure when configured correctly — not a DIY office PC.

---



## What we recommend saying to the client

1. **If no strong preference:** start with **Option 1 — DigitalOcean Managed MySQL** (~$15–30/month). Simple bill, matches the MySQL spec, enough for this archive.
2. **If the company is all-in on Google:** **Option 2 — Google Cloud SQL (MySQL)**.
3. **If they already live on AWS:** **Option 3 — Amazon RDS**.
4. **If they want the easiest “open a website and see tables” experience:** **Option 4 — Supabase (Postgres)** — and we adjust the engine to PostgreSQL.



### Suggested next step after they pick

1. Client creates the cloud account (in **their** name — they own the data).
2. Developer creates the empty database + secure user.
3. Share connection details privately (never in chat/email long-term).
4. Run dry-run load → July / full historical load → live incremental sync.



### What the client does **not** need to decide yet

- Exact table design (that follows the archive workbook).  
- Exact machine size forever (we can start small and upgrade).  
- High availability / multi-region (optional later when data or uptime requirements grow).

---



## Rough PHP mental math (optional)

Cloud bills are usually in **USD**. As a rough guide only (exchange rates move):  
**$15 ≈ ₱850–900**, **$30 ≈ ₱1,700–1,800**, **$50 ≈ ₱2,800–3,000** (illustrative).

---



## Decision checklist (for the client)

- [ ] Prefer **simple monthly bill** → lean DigitalOcean  
- [ ] Prefer **Google ecosystem** → lean Cloud SQL  
- [ ] Already on **AWS** → lean RDS  
- [ ] Want **easiest website UI** and OK with Postgres → lean Supabase  
- [ ] Comfortable monthly budget for the archive: $______  
- [ ] Who will own the cloud account / credit card: ________  
- [ ] Preferred region (e.g. Singapore / nearby): ________  

---



## Agent note

When the client picks an option, update `understanding.md` §7 (MySQL hosting) and §8 (Decisions) with the choice, account owner, and region.