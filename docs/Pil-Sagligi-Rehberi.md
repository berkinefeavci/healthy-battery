# Pil Sağlığı Rehberi

> 2026-10-06 · Claude · MacBook Pro M5 Pro (Mac17,8), macOS 27, Li-ion polimer, tasarım kapasitesi 8579 mAh, 12 döngü, sağlık %100

## 1. Bilim ne diyor (kısa)

Pil iki yoldan yaşlanır:
- **Takvim yaşlanması:** Pil kullanılmasa da zamanla yıpranır. Bunu yüksek doluluk ve sıcaklık hızlandırır.
- **Döngü yaşlanması:** Doldurup boşaltmanın yarattığı yıpranmadır.

Masada sürekli takılı duran bir Mac'te asıl yıpranma kaynağı takvim yaşlanmasıdır.

| Etken | Etkisi | Kaynak |
|---|---|---|
| **Sıcaklık** | En büyük düşman. Pil 30 °C'nin üstünde "sıcak" sayılır. Ortam 35 °C'yi geçerse kalıcı kapasite kaybı olabilir. Kabaca her +10 °C yıpranmayı iki katına çıkarır. | Apple, Battery University BU-808 |
| **Yüksek doluluk** | Bir yıl bekletmede: 25 °C'de %40 dolulukta kapasitenin %96'sı kalıyor, %100 dolulukta %80'i. 40 °C'de bu değerler %85 ve %65. | BU-808 Tablo 3 (eski ve yaklaşık veri) |
| **Sıcak + dolu birlikte** | En kötü ikili: %100 doluluk ve sıcaklık bir aradayken yıpranma en hızlı. | BU-808, takvim yaşlanması çalışmaları |
| **Döngü derinliği** | Küçük, orta aralıktaki döngüler çok daha az yıpratır. %75–25 aralığında ~3000, %100–25 aralığında ~300–500 tam döngü eşdeğeri. | BU-808 Şekil 6 |
| **Çok düşük doluluk** | %0'a kadar boşaltmak ve boş bekletmek zararlı. Silikon katkılı anotlarda düşük dolulukta döngü de hızlı yıpratıyor. | Apple (depolama), Dahn grubu (NMC/Si-grafit) |
| **Şarj gücü (watt)** | Adaptörün wattı tek başına önemli değil; akımı Mac belirler. Hızlı şarj yalnızca ürettiği ısı kadar zarar verir. | Apple Topluluk, Linus Tech Tips |
| **Bellek etkisi** | Yok. Sağlık için tam boşaltmak gerekmez. | BU-808 |

**Apple'ın resmî çizgisi:**
- Pil 1000 tam döngüde kapasitesinin %80'ini korumak üzere tasarlanmıştır.
- Sürekli takılı kullanıyorsan şarj sınırını %80'e çekmek yardımcı olur (Optimize Şarj ve Şarj Sınırı).
- Uzun süre kullanılmayacaksa pil %50'de, 32 °C'nin altında saklanmalı ve 6 ayda bir %50'ye tamamlanmalı.
- Mac yastık, battaniye gibi yumuşak bir yüzeyde şarj edilmemeli.
- Isınan kılıf şarj sırasında çıkarılmalı.

**Abartılmaması gerekenler:**
- BU-808'deki rakamlar eski hücrelerden geliyor; yön doğru ama rakamlar yaklaşık.
- Bazı sitelerdeki "Apple'ın iç araştırması %50–75 diyor" iddiası şarj aleti satan bir siteden geliyor ve doğrulanmadı.
- Pil sağlığı birkaç puan oynar. Fark yıllar içinde görünür, haftalar içinde görünmez.

## 2. Ana kurallar

1. **Günlük doluluk aralığı %20–80.** Masada sürekli takılıysa %80 sınırı yeterli. Daha düşük (%60–75) biraz daha iyidir, ama bunun bedeli sığ döngülerdir.
2. **%100 yalnızca gerektiğinde.** Yola çıkmadan 1–2 saat önce doldur ve %100'de uzun süre bekletme.
3. **Isıyı yönet.**
   - Şarj sırasında yumuşak yüzey ve kapalı çanta olmasın.
   - Güneşte ya da arabada bırakma.
   - Pil 35 °C'nin üstündeyse şarjı ertele.
4. **Dibe vurma.** %10–15'in altına inmeden tak; boş pille bekletme.
5. **Watt'a takılma.** 60 W ya da 140 W fark etmez. Önemli olan pilin sıcaklığı.
6. **Kalibrasyon sağlık için değil, göstergenin doğruluğu için.** Pil hep dar bir aralıkta kullanılıyorsa ayda bir kez 100 → ~15 → 100 tam döngü yeterli. Bu isteğe bağlıdır.

## 3. Senaryolar

### A. Evde, masada, sürekli takılı (ana durum)
- **Yap:**
  - Şarj sınırını %80'e çek.
  - Mac'i neredeyse hiç pille kullanmıyorsan adaptör modunu %70–75 hedefle açabilirsin (deneysel).
- **Yapma:**
  - Sınırı sürekli %100'de tutma.
  - Mac'i ısı kaynağının yanına ya da kapalı rafa koyma.

### B. Yatakta veya kanepede
- **Yap:**
  - Altına sert bir şey koy (tepsi, kitap, laptop sehpası).
  - Mümkünse kabloyu çıkarıp pille kullan; %80'den %40'a inmek zararsız bir döngüdür.
- **Yapma:**
  - Battaniye, yorgan ya da yastık üstünde hem şarj edip hem ağır iş yapma; bu en sıcak senaryodur.
  - Kapağı kapalı, şarjda, örtü altında bırakma.

### C. 60 W USB-C kabloya geçince
- Pil sağlığı açısından sorun yok; daha düşük güç pili biraz daha serin şarj eder.
- Ağır iş sırasında Mac 60 W'tan fazla çekebilir. Bu durumda pil takılıyken bile yavaşça boşalabilir. Bu normaldir, zarar vermez; sadece şarj yavaşlar.
- Kalite önemli: kablo ve adaptör USB-C PD sertifikalı olsun. Ucuz ve ısınan adaptörden kaçın.

### D. Dışarı çıkmadan önce
- **Yap:**
  - Gün uzun olacaksa çıkmadan 1–2 saat önce %100'e doldur (Doldur ya da "Şu saatte %100 hazır olsun").
  - Kısa bir çıkışsa %80 yeterli; doldurmaya gerek yok.
- **Yapma:** Bir gün önceden %100'e doldurup bütün gece takılı bekletme.

### E. Dışarıda bütün gün pille
- Rahatça kullan; pil bunun için var. %100'den %20'ye inmek bir döngünün yaklaşık %80'idir ve Apple 1000 döngü için tasarlıyor.
- **Yap:**
  - %20'ye yaklaşınca Düşük Güç Modu'nu aç.
  - 60 W adaptör yanındaysa ve fırsat çıkarsa kısa ara şarjlar yap; sık ve kısa şarj, derin tek şarjdan iyidir.
- **Yapma:**
  - %0'a kadar kullanıp Mac'i kendiliğinden kapanmaya bırakma.
  - Boş pille çantada saatlerce bekletme.
  - Sıcak bir arabada ya da güneşte bırakma.

### F. Eve dönünce
- Pil düşükse (<%30) hemen tak; sınır %80 olsun.
- Pil yüksekse (%90–100) ve Mac uzun süre takılı kalacaksa:
  - Kabloyu takmadan bir süre pille kullan.
  - Ya da adaptör modu açıksa pili kendiliğinden hedefe indirmesine izin ver.

### G. Birkaç gün ya da hafta kullanmayacaksan
- Pili ~%50'ye getir, Mac'i kapat, serin bir yerde sakla. 6 aydan uzun saklanacaksa 6 ayda bir %50'ye tamamla.

### H. Çanta ve taşıma
- Mac'i çantaya koymadan önce tamamen uyuttuğundan emin ol. Kapak kapalıyken bir uygulama Mac'i uyanık tutarsa çantada ısınır.
- Şarj olurken çantaya koyma.

## 4. Healthy Battery'nin bu rehberden çıkaracağı otomatik davranışlar

| Kural | Uygulamadaki karşılığı | Durum |
|---|---|---|
| %80 sınırı | macOS şarj sınırı ve çelişki uyarısı | Var (1.3.x) |
| %100'de uzun bekleme | Pil 3 saat %95'in üstündeyse uyarı | Var |
| Isı | 35 °C'de sınırı %80'e çek, Turbo'yu kapat | Var (açılması gerekiyor) |
| Yola hazırlık | "Şu saatte %100 hazır olsun" zamanlaması | Var |
| Masada %60–75 | Adaptör modu | Var (deneysel, fiziksel test bekliyor) |
| Dibe vurma | %15'te bildirim ve Düşük Güç Modu önerisi | **Eksik**, eklenecek |
| Yumuşak yüzey veya kapalı kapakta ısı | Şarjdayken pil 35 °C'yi geçince "havalandırmayı kontrol et" bildirimi | **Eksik**, eklenecek |
| Eve dönüş, yüksek doluluk | Pil %95+ iken takılınca "Pille kullanarak indir" önerisi ya da adaptör modu | **Eksik**, eklenecek |
| Uzun saklama | "Bir süre kullanmayacağım" düğmesi (pili %50'ye getirir) | **Eksik**, adaptör modu gerekir |
| Gösterge kalibrasyonu | Ayda bir tam döngü hatırlatması (isteğe bağlı) | **Eksik**, eklenecek |

## Kaynaklar
- [Apple – Optimize Şarj ve Şarj Sınırı](https://support.apple.com/en-us/102338)
- [Apple – Pil performansını en üst düzeye çıkarma](https://www.apple.com/batteries/maximizing-performance/)
- [Apple – Mac dizüstü çalışma sıcaklıkları](https://support.apple.com/en-us/102336)
- [Apple – Döngü sayısı](https://support.apple.com/en-us/ht201585)
- [Battery University BU-808](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/)
- [Takvim yaşlanması: grafit anot etkisi (J. Electrochem. Soc.)](https://iopscience.iop.org/article/10.1149/2.0411609jes)
- [Sıcaklık ve doluluğun uzun süreli depolamaya etkisi (PMC)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12219620/)
- [NMC/Si-grafit hücrelerde doluluk aralığı ve sıcaklık (J. Electrochem. Soc.)](https://iopscience.iop.org/article/10.1149/1945-7111/add382)
- [LFP'de tam dolu döngünün etkisi (InsideEVs, Dahn grubu)](https://insideevs.com/news/731210/lfp-battery-health-degrades-full-charge-study-finds/)
- [HN: Yalnızca %80'e şarj tartışması](https://news.ycombinator.com/item?id=38317893)
- [Linus Tech Tips: 140 W şarj pili yıpratır mı?](https://linustechtips.com/topic/1633629-would-140w-charger-degrade-macbook-battery-faster/)
- [MacRumors: Kapalı kapakta şarjda ısınma](https://forums.macrumors.com/threads/macbook-pro-16-with-apple-silicon-gets-hot-while-charging-closed.2340471/)
- [Apple güvenlik bilgisi: yumuşak yüzeyler](https://support.apple.com/en-la/guide/macbook-air/important-safety-information-apd9b8f7aa11/2019/mac/10.14.5)
