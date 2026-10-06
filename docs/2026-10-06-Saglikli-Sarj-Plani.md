# Healthy Battery — Sağlıklı Şarj Planı

> 2026-10-06 · Claude · Kurulu sürüm 1.2.4 (yerel), Mac17,8, 12 döngü, sağlık %100

## 1. Neden %80'de kaldı?

Canlı kayıtlar (`~/Library/Application Support/Cellkeep/`):

| Zaman | Olay |
|---|---|
| 1 Eki 14:50 | Healthy Battery hedefi %100 olarak kaydedildi (`charge-policy.json`) |
| 4 Eki 21:59 | macOS'un yerel şarj sınırı **%80** oldu (`history.json → limitEvents`). Değişikliği uygulama yapmadı. Sistem Ayarları → Pil → Şarj Sınırı ya da bir Kestirme olabilir (teyit edilmedi). |
| 4–6 Eki | Mac %80'de durdu. Uygulamanın tercihi (`chargeLimit = 100`) değişmediği için panel yine "Sınır %100" gösterdi. |
| 6 Eki 12:20 | Doldur (Top Up) başladı: yerel sınır 80 → 100. Pil şu an 4,7 A ile şarj oluyor. |
| Doldur bitince | Uygulama **%80'e geri dönecek** (`restoreLimit: 80`), çünkü Doldur öncesindeki değeri geri yükler. |

Kısacası şarjı durduran macOS'tu, uygulama değil. Uygulama çelişkiyi yakalıyor (`pausedByConflict`), ama yalnızca ayrıntı kartında küçük bir uyarı olarak gösteriyor. Üst bardaki "Sınır" değeri macOS'tan okunmuyor, uygulamanın kendi tercihinden geliyor. Ekranda görünen sınır ile gerçek sınır bu yüzden birbirinden ayrıldı.

## 2. Bugünkü zayıflıklar

- **Göstergeler iyi ama gerçekte yapılan iş az.** Uygulamanın tek gerçek eylemi macOS'un sınırını değiştirmek (yalnızca 80/85/90/95/100).
- **Isı koruması açık görünüyor ama hiçbir şey yapmıyor.** Bu Mac'te `heatProtection = 1`, fakat kodda tercih yalnızca kaydediliyor. Yelken (Sailing) için de durum aynı.
- Deşarj ve Kalibrasyon kilitli.
- %80'in altında sınır yok. Adaptör takılıyken şarjı durdurup pilden çalışma imkânı da yok.
- Pil uzun süre %100'de ya da sıcakken şarj olursa uyarı veya otomatik tepki yok.

## 3. Sağlıklı şarjın kuralları (uygulamanın uygulaması gerekenler)

1. Günlük kullanımda pili %20–80 arasında tut. Masada sürekli takılı kalan Mac'te %80, hatta mümkünse %60–75 daha iyi.
2. Pili uzun süre %100'de ve takılı bırakma. %100'ü yalnızca yola çıkmadan önce iste.
3. Sıcakken şarj etme. Pil 35 °C'yi geçerse şarjı duraklat.
4. Sınırda sürekli %79↔80 arasında küçük şarjlarla gidip gelme. Yelken ile 5 puanlık bir aralıkta boşalmasına izin ver.
5. Ayda bir kalibre et (100 → ~15 → 100), böylece yüzde göstergesi doğru kalır.

## 4. Fazlar

### Faz 1 — Doğru gösterge, ölü düğme yok (yetki gerekmez · 1 sürüm)
- Paneldeki "Sınır" her zaman macOS'tan okunan gerçek değeri göstersin.
- macOS'la çelişki olduğunda panelin üstünde belirgin bir şerit çıksın: **"macOS sınırı %80 — Healthy Battery %100 istiyor"**, yanında [Hedefimi uygula] [macOS değerini kullan] düğmeleri olsun.
- Dışarıdan yapılan değişiklik için Ayarlar'da bir tercih olsun: *Sor* (varsayılan) / *Hedefimi geri yaz* / *Benimse*.
- Doldur başlarken "Bitince %X'e dönülecek" yazısı görünsün.
- Isı koruması ve Yelken düğmeleri gerçekten çalışana kadar "Yakında" diye kilitli dursun. Açık görünüp hiçbir şey yapmasınlar.

### Faz 2 — Yerel sınırla yapılabilen akıllı eylemler (yeni yetki gerekmez)
- Varsayılan hedef %80 olsun. Takvimde yolculuk ya da toplantı varsa veya kullanıcı "yarın 08:00'de dolu olsun" derse, Doldur'u tam zamanında başlat.
- **Isı koruması v1:** Pil 35 °C'yi geçerse sınırı geçici olarak %80'e çek, Turbo'yu kapat ve bildirim gönder. Pil 32 °C'ye inince eski hedefe dön. (Sınırlama: pil zaten %80'in altındaysa şarjı durduramaz.)
- **%100'de bekleme uyarısı:** Pil 3 saatten uzun süre %95'in üstünde ve takılıysa bildirim gönder; tek tıkla %80'e dönülebilsin.
- **Sağlık kartı:** Son 7 günde %100'de geçen süre, sıcakken şarj edilen süre, ortalama döngü derinliği ve kısa bir öneri.
- macOS'un Optimize Şarj özelliğiyle çakışmayı algıla ve açıkla.

### Faz 3 — Gerçek şarj durdurma (en büyük kazanç, en büyük risk)
Kilitli dört özelliğin hepsi aynı yeteneğe bağlı: **adaptör takılıyken şarjı durdurmak ya da Mac'i pilden çalıştırmak.** Bunun için SMC'ye root yetkisiyle yazan bir yardımcı gerekir. AlDente de bu yolu kullanıyor.
- Aday SMC anahtarları: Apple Silicon'da `CHTE` (şarjı durdur) ve `CHIE` (adaptörü kes / deşarj). **Bu Mac'te teyit edilmedi.** Önce salt okunur bir prob çalıştırılacak (`Tools/PowerLimitProbe.m` bunun için genişletilebilir).
- Bu yetenek şunları açar: %20–100 arasında istenen her sınır, Yelken, gerçek ısı koruması, uykuda şarjı durdurma, Deşarj ve Kalibrasyon.
- **Güvenlik kuralları (vazgeçilmez):**
  - Yardımcıda bir bekçi süreci olsun: uygulama 60 saniye sinyal vermezse şarj yeniden açılsın.
  - Pil %10'un altına inerse her koşulda şarj olsun.
  - Kablo çıkarılınca, uyku/uyanmada ve sistem kapanırken şarj durumu varsayılana dönsün.
  - Rakip bir uygulama (AlDente vb.) çalışıyorsa kilitlensin.
  - Her yazmadan sonra değer okunarak doğrulansın.
- Fiziksel test protokolü:
  1. %85 → %80'de akım 0 oluyor mu?
  2. Uygulama öldürülünce şarj geri açılıyor mu?
  3. Kablo çıkar/tak.
  4. Uyku/uyanma.
  5. Deşarjda adaptör geri geliyor mu?
- Kurulum sırasında tek seferlik yönetici şifresi istenir; mevcut yardımcı modeli (`powermode`, `led`) ile aynı yapıda olur.

### Faz 4 — Faz 3'ün üzerine kurulan özellikler
- **Yelken:** Örneğin 75–80 arasında; pil 75'e inene kadar şarj etmesin.
- **Isı koruması v2:** 35 °C'nin üstünde şarjı gerçekten duraklat.
- **Uyku davranışı:** Uykuda sınırın üstüne çıkmasın.
- **Deşarj:** Pil sınırın üstündeyse adaptör takılıyken pilden çalışarak hedefe insin.
- **Kalibrasyon sihirbazı:** Ayda bir hatırlatsın ve adımları otomatik yürütsün.

## 5. Kararlar (Berkin)
- K1: Faz 3'e (SMC root yardımcısı) gidilecek mi? Gidilmezse uygulama Faz 2'de kalır ve %80 altı ile Yelken hiç gelmez.
- K2: Dışarıdan yapılan sınır değişikliğinde varsayılan davranış ne olsun: Sor / Geri yaz / Benimse?
- K3: Varsayılan hedef %80 mi olsun?
