# PULSE | Gaming Tweak — KFLI // The Digital Shadow

أداة بواجهة رسومية (GUI) لتحسين أداء ويندوز للألعاب — Power Plan، Game Mode، جدولة معالجة الألعاب، GPU Scheduling (HAGS)، تعطيل Nagle's Algorithm، تنظيف الملفات المؤقتة، وأكثر — مع نسخة احتياطية تلقائية للقيم الأصلية وإمكانية استرجاعها بالكامل.

## ⚡ التثبيت والتشغيل

افتح **PowerShell كـ Administrator** والصق الأمر التالي:

```powershell
iwr -useb https://raw.githubusercontent.com/kfli1/KFLI-Tweaks/refs/heads/main/install.ps1 | iex
```

البرنامج بيتحمّل تلقائيًا ويفتح واجهته الرسومية. أول مرة تشغّله، بيسوي System Restore Point بالخلفية قبل أي تعديل.

## ✨ المميزات

- **بدون تجميد**: كل التعديلات وجمع الإحصائيات (CPU/RAM/GPU/VRAM) تشتغل في الخلفية، والواجهة تبقى متجاوبة دايمًا.
- **نسخة احتياطية حقيقية**: القيم الأصلية تُحفظ في `PULSE-Backup.json`، وزر "Restore Changes" يرجّعها كما كانت بالضبط (مو مجرد تفعيل خطة طاقة افتراضية).
- **سجل مفصّل**: كل خطوة تسجّل نجاحها أو فشلها الفعلي في `PULSE-Tweak-Log.txt`.
- **آمن**: لا يمس Windows Defender ولا Firewall ولا Windows Update، ويحاول دائمًا إنشاء نقطة استعادة قبل التعديل.

## 🛠️ التعديلات المتوفرة

| التعديل | الوصف |
|---|---|
| Power Plan | تفعيل High Performance أو Ultimate Performance |
| Game Mode | تفعيل/تعطيل Game Mode في ويندوز |
| Game Task Priority | رفع أولوية جدولة الألعاب في المعالج والـ GPU |
| HAGS | تفعيل Hardware-Accelerated GPU Scheduling |
| Fullscreen / Game DVR | ضبط تحسينات الشاشة الكاملة وتعطيل تسجيل Game DVR |
| Nagle's Algorithm | تعطيله لتقليل زمن استجابة الشبكة |
| Visual Effects | تقليل التأثيرات المرئية لأداء أفضل |
| Temp Cleanup | تنظيف الملفات المؤقتة وسلة المحذوفات |

## 🔄 استرجاع كل التغييرات

من داخل الواجهة، زر **Restore Changes** يرجّع كل القيم إلى حالتها الأصلية كما كانت قبل أول تشغيل.

يمكنك أيضًا استخدام **System Restore** في ويندوز والرجوع إلى نقطة الاستعادة التي أنشأها البرنامج تلقائيًا باسم:
`PULSE Gaming Tweak - before changes`

## 📂 ملفات البرنامج

بعد أول تشغيل، تجد هذه الملفات في `%LOCALAPPDATA%\PULSE\`:
- `PULSE-Tweak-Log.txt` — سجل كل العمليات
- `PULSE-Backup.json` — نسخة القيم الأصلية (تُستخدم عند الاسترجاع)

## ⚠️ ملاحظات

- يتطلب تشغيله بصلاحيات **Administrator** (يعيد تشغيل نفسه تلقائيًا إذا لزم).
- بعض التعديلات (Visual Effects، HAGS) تحتاج إعادة تسجيل دخول أو إعادة تشغيل للجهاز حتى تُطبّق بالكامل.
- مخصص لأنظمة **Windows 10 / 11**.

---

صُنع بواسطة **KFLI // The Digital Shadow**
