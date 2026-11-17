# Docker Storage Manager

ابزارهای Bash برای **ممیزی، گزارش‌گیری و پاک‌سازی کنترل‌شده فضای Docker** روی Linux.

این مخزن دو اسکریپت دارد:

- `scripts/docker-storage-audit.sh` — گزارش‌گیری فقط‌خواندنی از وضعیت Docker، Containerd، Imageها، Containerها، Volumeها، Networkها، Build Cache و فایل‌های Log.
- `scripts/docker-storage-cleanup.sh` — پاک‌سازی مبتنی بر Policy با حالت **Dry-run به‌صورت پیش‌فرض**. عملیات حذف فقط با `--apply` انجام می‌شود. بررسی/حذف Volumeها نیز فقط با گزینه جداگانه `--weekly-volumes` فعال می‌شود.

> زبان مستندات فارسی است؛ نام دستورات، متغیرها و اصطلاحات فنی مطابق ابزارهای اصلی Docker نگه داشته شده‌اند.

---

## فهرست مطالب

- [ویژگی‌ها](#ویژگیها)
- [پیش‌نیازها](#پیشنیازها)
- [معماری Storage در Docker](#معماری-storage-در-docker)
- [ساختار مخزن](#ساختار-مخزن)
- [نصب](#نصب)
- [استفاده از Audit](#استفاده-از-audit)
- [استفاده از Cleanup](#استفاده-از-cleanup)
- [Policy پیش‌فرض Cleanup](#policy-پیشفرض-cleanup)
- [محافظت از Volumeها](#محافظت-از-volumeها)
- [زمان‌بندی نمونه](#زمانبندی-نمونه)
- [نکات Production](#نکات-production)
- [عیب‌یابی](#عیبیابی)

---

## ویژگی‌ها

### Audit

اسکریپت Audit چیزی را حذف یا تغییر نمی‌دهد و اطلاعات زیر را جمع‌آوری می‌کند:

- نسخه Docker Engine، Docker Root، Storage Driver و Logging Driver
- ظرفیت Filesystem و مصرف Inodeها
- خروجی `docker system df -v`
- Containerهای فعال و متوقف، Writable Size و Mountهایشان
- Imageها، Tagها و Digestها
- Volumeها، Driver، Mountpoint، تاریخ ایجاد و Labelها
- اندازه Volumeهای Local در صورت فعال کردن اسکن اختیاری
- Docker Networks
- Build Cache و فهرست Buildx Builderها
- تنظیم Logging Driver و مسیر Log هر Container
- بزرگ‌ترین فایل‌های `json-file` log
- مصرف دایرکتوری‌های Docker و Containerd و فایل‌های بزرگ آن‌ها

گزارش در مسیر زیر ذخیره می‌شود:

```text
/var/log/docker-storage-audit/
```

هر گزارش با نام میزبان و Timestamp ساخته می‌شود.

### Cleanup

اسکریپت Cleanup این منابع را به‌ترتیب بررسی می‌کند:

1. Containerهای متوقف‌شده/ایجادشده قدیمی
2. Networkهای بلااستفاده قدیمی
3. Imageهای بدون Container وابسته و قدیمی
4. Build Cache استفاده‌نشده و قدیمی (Builder پیش‌فرض Docker)
5. Volumeهای Local جداشده، فقط در اجرای هفتگی و با گزینه صریح

خروجی در ترمینال نمایش داده می‌شود و هم‌زمان در فایل زیر ثبت می‌شود:

```text
/var/log/docker-storage-cleanup.log
```

---

## پیش‌نیازها

- Linux با Bash 4 یا جدیدتر
- Docker Engine و Docker CLI که کاربر اجراکننده به Daemon دسترسی داشته باشد
- GNU coreutils و ابزارهای معمول Ubuntu/Debian: `df`, `du`, `find`, `sort`, `awk`, `sed`, `stat`, `date`, `tee`, `grep`
- برای اجرای Cleanup، دسترسی `root` لازم است.
- برای اسکن دقیق حجم Volumeها، دسترسی خواندن مسیرهای Mountpoint لازم است.

اسکریپت‌ها برای Ubuntu/Debian و GNU coreutils نوشته و با `bash -n` از نظر Syntax بررسی شده‌اند. اجرای واقعی روی تمام نسخه‌ها، Storage Driverها و Volume Pluginها تضمین نشده است.

---

## معماری Storage در Docker

مسیر ذخیره‌سازی به نوع Image Store و Storage Backend بستگی دارد. دو معماری را نباید با هم اشتباه گرفت.

### ۱. Containerd Image Store

در نصب‌های تازه Docker Engine 29 و بالاتر، Containerd Image Store به‌صورت پیش‌فرض استفاده می‌شود. در این حالت معمولاً:

```text
/var/lib/
├── containerd/     # Image content و Container snapshots
└── docker/         # سایر stateهای Docker، از جمله Local Volumes
```

مسیرهای مهم Containerd در نصب معمول:

```text
/var/lib/containerd/
├── io.containerd.content.v1.content/
│   └── blobs/                         # OCI content blobs
├── io.containerd.snapshotter.v1.overlayfs/
│   └── snapshots/                     # Unpacked layers و snapshots
├── io.containerd.metadata.v1.bolt/    # Metadata داخلی
└── ...
```

- **Blob / Content:** محتوای دریافت‌شده از Registry، مانند Manifest، Config و Layer Blob.
- **Snapshot:** وضعیت فایل‌سیستم که توسط Snapshotter مدیریت می‌شود. Layerهای Image معمولاً Snapshotهای read-only/committed هستند.
- **Active Snapshot:** لایه قابل‌نوشتن مختص Container.
- **Container Filesystem:** نمای یکپارچه‌ای که Container می‌بیند؛ در Snapshotter مبتنی بر OverlayFS از Layerهای پایین‌دستی و لایه قابل‌نوشتن بالایی ساخته می‌شود.

Containerd ممکن است Layer فشرده‌شده را در Content Store و نسخه Extract‌شده را در Snapshotter نگهداری کند. به همین دلیل مصرف فیزیکی Image Store می‌تواند از عددی که با جمع‌زدن ساده اندازه Imageها به‌دست می‌آید بیشتر باشد.

### ۲. Storage Backend کلاسیک

در نصب‌های ارتقایافته یا پیکربندی‌های قدیمی‌تر ممکن است Docker از Storage Driver کلاسیک مانند `overlay2` استفاده کند. در آن حالت بخش عمده Image و Container filesystem زیر Docker Root، معمولاً `/var/lib/docker`, قرار می‌گیرد.

### تشخیص Backend فعال

```bash
docker info --format 'Version={{.ServerVersion}} Root={{.DockerRootDir}} Driver={{.Driver}} DriverStatus={{json .DriverStatus}}'
```

اگر خروجی `DriverStatus` شامل زیر باشد، Docker از Containerd Snapshotter استفاده می‌کند:

```text
io.containerd.snapshotter.v1
```

### انواع Mount

| نوع | محل داده | با حذف Container |
|---|---|---|
| Writable layer / Active snapshot | لایه قابل‌نوشتن Container | حذف می‌شود |
| Named Volume | Volume backend؛ در Local Driver معمولاً زیر `/var/lib/docker/volumes` | باقی می‌ماند |
| Bind Mount | مسیر مشخص‌شده روی Host | باقی می‌ماند |
| tmpfs | حافظه موقت Host | با توقف/حذف Container از بین می‌رود |

**نکته:** Mount به معنی Hard Link نیست. Volume و Bind Mount یک Storage را از مسیر داخل Container در دسترس قرار می‌دهند؛ داده صرفاً به دلیل Mount شدن دوباره کپی نمی‌شود. در صورت استفاده از Volume خالی روی یک مسیر غیرخالی Image، Docker ممکن است محتوای اولیه آن مسیر را در Volume کپی کند، مگر اینکه رفتار `volume-nocopy` انتخاب شود.

**هشدار:** فایل‌ها و Metadata داخلی `/var/lib/docker` و `/var/lib/containerd` را دستی حذف یا ویرایش نکنید. برای مدیریت Resourceها از Docker CLI/API استفاده کنید.

---

## ساختار مخزن

```text
docker-storage-manager/
├── README.md
├── .gitignore
├── scripts/
│   ├── docker-storage-audit.sh
│   └── docker-storage-cleanup.sh
└── examples/
    ├── protected-volumes.txt
    └── docker-storage-maintenance.cron
```

---

## نصب

مخزن را Clone کنید:

```bash
git clone <YOUR_GITHUB_REPOSITORY_URL>
cd docker-storage-manager
```

مجوز اجرا بدهید:

```bash
chmod 0750 scripts/docker-storage-audit.sh
chmod 0750 scripts/docker-storage-cleanup.sh
```

دایرکتوری تنظیمات Volumeهای محافظت‌شده را ایجاد کنید:

```bash
sudo install -d -m 0750 /etc/docker-storage-cleanup
sudo install -m 0640 examples/protected-volumes.txt \
  /etc/docker-storage-cleanup/protected-volumes.txt
```

فایل نمونه فقط Comment دارد. نام واقعی Volumeهای مهم را، هر کدام در یک خط، اضافه کنید:

```text
# One Docker volume name per line.
# Lines beginning with # are comments.
shop-auth-stack_postgres_data
nexus-data
```

اسکریپت نام Volume را دقیقاً با این فایل تطبیق می‌دهد.

### نصب اختیاری در PATH

```bash
sudo install -m 0750 scripts/docker-storage-audit.sh \
  /usr/local/sbin/docker-storage-audit.sh

sudo install -m 0750 scripts/docker-storage-cleanup.sh \
  /usr/local/sbin/docker-storage-cleanup.sh
```

---

## استفاده از Audit

اجرای عادی:

```bash
sudo ./scripts/docker-storage-audit.sh
```

گزارش در `/var/log/docker-storage-audit/` ذخیره می‌شود.

### اندازه‌گیری حجم Volumeها

برای جلوگیری از اسکن بازگشتی و پرهزینه Volumeهای بزرگ، اندازه‌گیری محتوای Volumeهای Local به‌صورت پیش‌فرض خاموش است. برای فعال کردن آن:

```bash
sudo env SCAN_VOLUME_SIZES=1 \
  ./scripts/docker-storage-audit.sh
```

این گزینه از `du -sh` روی Mountpoint هر Volume Local استفاده می‌کند. روی Volumeهای بسیار بزرگ یا Storageهای کند می‌تواند I/O ایجاد کند؛ در Production با احتیاط اجرا شود.

### Containerd root سفارشی

مسیر پیش‌فرض اسکریپت `/var/lib/containerd` است. اگر Containerd در مسیر دیگری پیکربندی شده، مسیر واقعی را مشخص کنید:

```bash
sudo env CONTAINERD_ROOT=/mnt/containerd-data \
  ./scripts/docker-storage-audit.sh
```

---

## استفاده از Cleanup

### حالت پیش‌فرض: Dry-run

```bash
sudo ./scripts/docker-storage-cleanup.sh
```

حالت Dry-run هیچ Resourceای را حذف نمی‌کند. Candidateها و اقداماتی را که در حالت واقعی انجام می‌شد ثبت می‌کند. خروجی در ترمینال و فایل Log نمایش/ذخیره می‌شود.

### اجرای پاک‌سازی عادی

```bash
sudo ./scripts/docker-storage-cleanup.sh --apply
```

این حالت Policyهای عادی را اعمال می‌کند، ولی به Volumeها دست نمی‌زند.

### پاک‌سازی هفتگی Volumeها در حالت Dry-run

```bash
sudo ./scripts/docker-storage-cleanup.sh --weekly-volumes
```

### حذف واقعی Volumeهای واجد شرایط

```bash
sudo ./scripts/docker-storage-cleanup.sh \
  --apply --weekly-volumes
```

این عملیات فقط Volumeهای Local بدون اتصال به هیچ Container، قدیمی‌تر از Retention و غیرمحافظت‌شده را بررسی و حذف می‌کند. با این حال، **قدیمی و جداشده بودن به معنی بی‌ارزش بودن داده نیست**؛ ممکن است Volume دیتابیس خاموش یا سرویس موقتاً حذف‌شده باشد.

### شامل کردن Volumeهای مدیریت‌شده توسط Compose

به‌صورت پیش‌فرض Volumeهای دارای Label مربوط به Docker Compose محافظت می‌شوند. فقط پس از بررسی مالک و Backup می‌توان آن‌ها را هم در Sweep هفتگی وارد کرد:

```bash
sudo ./scripts/docker-storage-cleanup.sh \
  --apply --weekly-volumes --include-compose-volumes
```

این گزینه از Label محافظتی `com.example.docker-maintenance.keep=true` یا فایل `protected-volumes.txt` عبور نمی‌کند؛ آن محافظت‌ها همچنان برقرار هستند.

### مشاهده Help

```bash
sudo ./scripts/docker-storage-cleanup.sh --help
```

---

## Policy پیش‌فرض Cleanup

مقادیر از طریق Environment Variable قابل تغییر هستند.

| متغیر | مقدار پیش‌فرض | رفتار |
|---|---:|---|
| `CONTAINER_RETENTION_HOURS` | `48` | Container متوقف‌شده/ایجادشده قدیمی‌تر از این مدت حذف می‌شود |
| `IMAGE_RETENTION_HOURS` | `336` | Image بلااستفاده قدیمی‌تر از ۱۴ روز هدف قرار می‌گیرد |
| `NETWORK_RETENTION_HOURS` | `168` | Network بدون Container متصل و قدیمی‌تر از ۷ روز هدف قرار می‌گیرد |
| `BUILD_CACHE_RETENTION_HOURS` | `168` | Build Cache استفاده‌نشده با Last Use قدیمی‌تر از ۷ روز هدف قرار می‌گیرد |
| `BUILD_CACHE_KEEP` | `512MB` | فضای Cache گرمی که به `docker builder prune --keep-storage` سپرده می‌شود |
| `VOLUME_RETENTION_DAYS` | `7` | حداقل عمر Volume جداشده برای Sweep هفتگی |
| `PROTECTED_VOLUMES_FILE` | `/etc/docker-storage-cleanup/protected-volumes.txt` | فهرست Volumeهای محافظت‌شده |
| `LOG_FILE` | `/var/log/docker-storage-cleanup.log` | فایل Log اسکریپت Cleanup |

مثال تغییر Retention:

```bash
sudo env IMAGE_RETENTION_HOURS=720 \
  BUILD_CACHE_RETENTION_HOURS=336 \
  ./scripts/docker-storage-cleanup.sh --apply
```

یعنی Imageهای بلااستفاده فقط در صورتی هدف قرار می‌گیرند که بیش از ۳۰ روز از زمان ایجادشان گذشته باشد.

### نکات دقیق Policy

- عمر Container متوقف‌شده بر اساس زمان خروج (`FinishedAt`) محاسبه می‌شود؛ برای Containerهایی که هرگز شروع نشده‌اند، زمان ایجاد استفاده می‌شود.
- عمر Image بر اساس زمان ایجاد Image است، نه آخرین زمان Pull یا آخرین زمان اجرای Application.
- Imageهای موردنیاز Containerهای موجود حذف نمی‌شوند؛ اما Imageهای بدون Container وابسته، حتی اگر Tag داشته باشند، ممکن است با Policy حذف شوند.
- Network فقط وقتی کاندید می‌شود که Containerی به آن متصل نباشد و از Retention عبور کرده باشد.
- Build Cache مربوط به Builder پیش‌فرض Docker با `docker builder prune` مدیریت می‌شود. Builderهای مستقل Buildx ممکن است Cache جداگانه داشته باشند؛ Audit آن‌ها را فهرست می‌کند، اما Cleanup آن‌ها را به‌صورت خودکار Prune نمی‌کند.
- Volume فقط در صورت ارائه `--weekly-volumes` بررسی می‌شود.
- فقط Volumeهای Driver نوع `local` وارد Sweep می‌شوند؛ Pluginهای Volume خارجی به‌صورت محافظه‌کارانه Skip می‌شوند.
- Volumeهای Compose-managed پیش‌فرض محافظت می‌شوند، مگر اینکه `--include-compose-volumes` صریحاً داده شود.
- Label زیر و نام موجود در فایل Protected همیشه Volume را از Sweep مستثنا می‌کند:

```text
com.example.docker-maintenance.keep=true
```

---

## محافظت از Volumeها

### Label محافظتی در Docker Compose

```yaml
services:
  postgres:
    image: postgres:16
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
    labels:
      com.example.docker-maintenance.keep: "true"
```

### محافظت از Volume موجود با فایل

```text
# /etc/docker-storage-cleanup/protected-volumes.txt
prod-postgres-data
prod-nexus-data
```

از آنجا که Volume ممکن است تنها نسخه داده یک Database باشد، پیش از حذف آن باید موارد زیر بررسی شود:

1. مالک و Application مربوط به Volume مشخص باشد.
2. مشخص شود آیا دیتابیس یا سرویس خاموشی از آن استفاده می‌کرده است.
3. Backup معتبر وجود داشته باشد.
4. Restore از Backup آزمایش شده باشد.
5. Retention و مجوز حذف تأیید شده باشد.

هیچ‌کدام از این اسکریپت‌ها از Volume Backup نمی‌گیرند و جایگزین Backup/Restore نیستند.

---

## زمان‌بندی نمونه

فایل `
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==========================================
# Docker Storage Management
# ==========================================

# 1. Storage Audit - Every 2 days at 02:00
0 2 */2 * * /usr/local/sbin/docker-storage-audit.sh

# 2. Regular Cleanup - Every 2 days at 02:30
30 2 */2 * * /usr/local/sbin/docker-storage-cleanup.sh --apply

# 3. Weekly Volume Review - Every Sunday at 03:00
# Dry-run only. No volumes will be deleted.
0 3 * * 0 /usr/local/sbin/docker-storage-cleanup.sh --weekly-volumes --include-compose-volumesexamples/docker-storage-maintenance.cron` یک نمونه Crontab ارائه می‌کند:

- Audit هر دو روز یک‌بار (بر اساس روزهای تقویمی Cron)
- Cleanup عادی هر دو روز یک‌بار
- بررسی هفتگی Volumeها در حالت Dry-run

برای نصب، مسیرها را در فایل نمونه با مسیر نصب واقعی خود تطبیق دهید و سپس آن را به Crontab کاربر root اضافه کنید:

```bash
sudo crontab -e
```

**توصیه:** پاک‌سازی Volume را خودکار و بدون Review فعال نکنید. ابتدا گزارش هفتگی Dry-run را بررسی کنید؛ سپس در صورت تأیید، فرمان `--apply --weekly-volumes` را دستی اجرا کنید.

---

## نکات Production

این ابزار برای Lab و نگهداری معمول Docker Host طراحی شده است، اما اجرای خودکار Policy حذف روی Production نیازمند Review متناسب با سرویس است.

- `docker image prune -a` می‌تواند Imageهای Rollback را حذف کند، حتی اگر هنوز Tag داشته باشند و Containerی به آن‌ها متصل نباشد.
- Container متوقف‌شده ممکن است تنها محل باقی‌ماندن تغییرات مهم Writable Layer باشد. قبل از حذف، این داده‌ها را بررسی کنید.
- Volume detached می‌تواند داده مهم و موردنیاز یک سرویس خاموش را نگهداری کند.
- `docker volume prune -a` یا `docker compose down -v` را به‌عنوان Cleanup روتین اجرا نکنید.
- از حذف دستی فایل‌ها در `/var/lib/docker` و `/var/lib/containerd` خودداری کنید.
- `docker system df` و `du` دو نوع اندازه‌گیری متفاوت ارائه می‌کنند. به دلیل Shared Layers، Snapshotها، Hard Linkها، Metadata و رفتار Filesystem، اعداد الزاماً برابر یا قابل جمع زدن نیستند.
- برای فایل‌های Log، Logging Driver و Rotation را تنظیم کنید. این اسکریپت Logهای فعال را truncate یا حذف نمی‌کند.
- در Docker Engine با Containerd Image Store، تنظیم `data-root` در `/etc/docker/daemon.json` به‌تنهایی مسیر Imageها و Snapshotهای Containerd را تغییر نمی‌دهد. مسیر Containerd باید جداگانه در `/etc/containerd/config.toml` مدیریت شود.
- پیش از جابه‌جایی Data Root یا Containerd Root، روش رسمی نسخه نصب‌شده را بررسی کنید؛ سرویس‌ها را متوقف کنید، Backup بگیرید، مسیر و Permissionها را حفظ کنید و راه‌اندازی و سلامت سرویس را تست کنید.
- این اسکریپت‌ها فقط Local Docker Engine را ممیزی و پاک‌سازی می‌کنند؛ Docker Swarm، Kubernetes node storage، Registry خارجی و Volume Pluginهای غیرمحلی نیازمند ابزار و Runbook جداگانه هستند.

---

## عیب‌یابی

### Docker daemon در دسترس نیست

```bash
sudo systemctl status docker
sudo docker info
```

### گزارش Audit کجا ذخیره می‌شود؟

```bash
sudo ls -lah /var/log/docker-storage-audit/
```

### لاگ Cleanup کجاست؟

```bash
sudo tail -n 100 /var/log/docker-storage-cleanup.log
```

### فضای واقعی Filesystem را بررسی کنید

```bash
df -hT
df -i
sudo du -xhd1 /var/lib/docker 2>/dev/null | sort -h
sudo du -xhd1 /var/lib/containerd 2>/dev/null | sort -h
```

### Docker Engine 29 و Containerd Image Store

```bash
docker info --format '{{.ServerVersion}} {{.Driver}} {{json .DriverStatus}}'
```

اگر از Containerd Image Store استفاده می‌کنید، انتظار نداشته باشید همه Image و Snapshotها زیر `/var/lib/docker` قرار داشته باشند.

---

## منابع رسمی

- [Docker — Containerd image store](https://docs.docker.com/engine/storage/containerd/)
- [Docker — Prune unused objects](https://docs.docker.com/engine/manage-resources/pruning/)
- [Docker — Volumes](https://docs.docker.com/engine/storage/volumes/)
- [Docker — Storage drivers](https://docs.docker.com/engine/storage/drivers/)
- [Docker CLI — `docker builder prune`](https://docs.docker.com/reference/cli/docker/builder/prune/)
- [Docker CLI — `docker system df`](https://docs.docker.com/reference/cli/docker/system/df/)

---

## مجوز

در این مخزن مجوز نرم‌افزاری (License) مشخصی اضافه نشده است. در صورت انتشار عمومی، پیش از انتخاب License موردنظر خود آن را به مخزن اضافه کنید.
