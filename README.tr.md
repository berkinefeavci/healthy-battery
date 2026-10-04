# Healthy Battery

🇬🇧 [English README](README.md)

**Apple Silicon MacBook'lar için ücretsiz ve açık kaynak batarya bakımı.** macOS'un %80–100 şarj sınırını ayarla, canlı güç akışını gör ve batarya sağlığını aylar boyunca izle — abonelik, hesap ya da veri toplama olmadan, küçük bir menü çubuğu uygulamasıyla.

<p align="center">
  <a href="../../releases/latest"><img alt="Son sürümü indir" src="https://img.shields.io/github/v/release/berkinefeavci/healthy-battery?label=%C4%B0ndir&style=for-the-badge"></a>
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-black?style=for-the-badge&logo=apple">
  <img alt="MIT lisansı" src="https://img.shields.io/github/license/berkinefeavci/healthy-battery?style=for-the-badge">
</p>

- %80–100 arası **şarj sınırı** ve yolculuk öncesi tek tıkla %100'e **Doldur**.
- **Canlı güç akışı**: adaptör, batarya, CPU, ekran — tahmin değil, ölçüm.
- **Uzun vadeli sağlık**: 400 güne kadar günlük özet, CSV dışa aktarma.
- Apple tarafından **imzalı ve notarize**, **açık kaynak** (MIT), veriler Mac'inde kalır ([PRIVACY.md](PRIVACY.md)).
- Türkçe, English, Deutsch, Français, Español.

## Ekran görüntüleri

<p align="center"><img src="docs/screenshots/demo.gif" alt="Healthy Battery menü çubuğu paneli: adaptörden işlemciye, ekrana ve diğer bileşenlere canlı güç akışı" width="400"></p>

<table>
<tr><td width="50%"><img src="docs/screenshots/panel-light.png" alt="Menü çubuğu paneli: %80 şarj sınırı, Doldur, canlı güç akışı ve güç modları" width="100%"></td><td width="50%"><img src="docs/screenshots/dashboard-light.png" alt="Gösterge Tablosu: batarya geçmişi grafikleri, şarj durumu ve uzun vadeli sağlık eğilimi" width="100%"></td></tr>
<tr><td width="50%"><img src="docs/screenshots/energy-light.png" alt="Enerji Kullanımı: macOS enerji etkisine göre uygulamalar, bağlı cihazlar ve güç akışı" width="100%"></td><td width="50%"><img src="docs/screenshots/magsafe-light.png" alt="MagSafe Işığı: macOS yönetsin, hep kapalı ya da belirli saatlerde kapalı" width="100%"></td></tr>
</table>

> Healthy Battery önce Cellkeep ve ChargeMate adıyla geliştirildi. Mevcut veriler, yardımcı kimlikleri ve Homebrew cask adı uyumluluk için Cellkeep olarak kalır.

## Özellikler

- **%80–100 şarj sınırı.** Healthy Battery, macOS'un kendi yerel şarj sınırı mekanizmasını (macOS Ayarlar'ın kullandığı aynı mekanizma) sürerek bataryayı %80 ile %100 arasında, %5'lik adımlarla bir hedefte tutar. Bir sınır uygulamak, bağımsız bir geri-okuma kontrolüyle doğrulanan gerçek bir okuma/yazma turudur — bunun ne kanıtlayıp ne kanıtlamadığı için [Sınırlamalar](#nasıl-çalışır-ve-sınırları) bölümüne bakın.
- **Doldur (Top Up).** Bir seyahat için geçici olarak %100'e şarj eder; ardından Healthy Battery önceki sınırınızı geri yükler.
- **Canlı güç akışı.** Adaptör, batarya, işlemci, ekran ve "diğer" gücün watt cinsinden diyagramı. İşlemci ve ekran watt değerleri Apple'ın SMC sensörlerinden, toplam sistem gücü ise batarya denetleyicisinden okunur. Hiçbir değer tahmin edilmez veya uydurulmaz; ölçülemiyorsa "—" gösterilir.
- **Bağlı cihaz gücü.** Tam olarak tek bir USB cihazı tek bir aktif portta güç çekiyorsa, Healthy Battery o cihazın watt değerini gösterir (batarya denetleyicisinin port telemetrisinden, salt-okunur). Birden fazla cihaz veya port varsa tahmin yerine "—" gösterilir.
- **Geçmiş grafikleri.** Şarj seviyesi, güç tüketimi ve batarya sağlığı için 1 saat / 6 saat / 24 saatlik görünümler. Kaydedilen ölçümler Ayarlar → Hakkında’dan CSV olarak dışa aktarılabilir.
- **Uzun vadeli sağlık ve alışkanlıklar.** 400 güne kadar günlük özet tutulur: batarya sağlığı eğilim grafiği ve son 7 ile 30 gün için ortalama doluluk, %90 ve üstünde geçen süre, eklenen döngü, sağlık değişimi ve en yüksek sıcaklık. CSV olarak dışa aktarılabilir.
- **Batarya sağlığı.** Günlük sensör gürültüsünün gerçek bir sağlık değişimi gibi görünmemesi için saatlik medyana yumuşatılmış maksimum kapasite grafiği.
- **Kaynağa göre güç modları.** Otomatik / Yüksek Güç (Turbo) / Tasarruf, "pilde" ve "adaptörde" ayrı ayrı izlenir; macOS'un kendi `pmset` güç profillerine, dar kapsamlı ve izin listeli bir yardımcı üzerinden yazılır.
- **Uyku davranışı.** İsteğe bağlı: adaptör bağlıyken ve hedefin altında şarj olurken, Healthy Battery genel (public) bir macOS boşta-uyku assertion'ı tutarak Mac'inizin uykuya geçmek yerine şarj olmaya devam etmesini sağlar. 8 saatlik güvenlik sınırı vardır; kapak kapatma veya ekran uykusuna hiç dokunmaz. Uyku sırasında şarjı kendiliğinden duraklatmaz — bkz. Sınırlamalar.
- **MagSafe LED denetimi.** İmzalı, dar kapsamlı ve yalnızca bilinen tek bir SMC anahtarına yazan bir ayrıcalıklı yardımcı üzerinden manuel Sistem / Yeşil / Turuncu / Kapalı denetimi, artı her zaman kapalı veya saatli bir politika.
- **Zamanlamalar (Schedules).** Bir sınır uygulama, güç modu değiştirme ve benzeri için tekrarlı veya tek seferlik eylemler; filtrelenebilir çalıştırma geçmişiyle.
- **Apple Kısayolları (Shortcuts) eylemleri.** Pil yüzdesi, sıcaklık ve durum okuma; sınır uygulama, Doldur başlatma/iptal etme, güç modu değiştirme veya MagSafe LED ayarlama için sekiz App Intent.
- **Çıkış ile yüksek enerjili uygulamalar.** Enerji listesi yardımcı süreçleri sahibi uygulama altında toplar, gerçek ikonu gösterir ve listeden doğrudan bir uygulamayı kapatmanıza izin verir.
- **Uygulama içinden güncelleme.** Healthy Battery günde en fazla bir kez GitHub'dan son sürüm numarasını sorar ve yeni sürüm çıkınca bir bildirim gösterir; ikisi de Ayarlar → Hakkında'dan kapatılabilir. **Güncelle**'ye basınca o sürümü indirir; sağlama değerini, Developer ID imzasını ve Apple onayını doğruladıktan sonra kendini değiştirip yeniden açılır. Hiçbir veri gönderilmez; bkz. [PRIVACY.md](PRIVACY.md).
- **Çakışma koruması.** Başka bir şarj limiti aracı çalışıyor ya da kuruluysa (AlDente, Battery Toolkit, BatFi, batt, battery, bclm) Healthy Battery izlemeye devam eder ama kendi limit yazmalarını kilitler; iki uygulama aynı ayar için çekişmez.
- **Genel kısayol (isteğe bağlı).** Varsayılan olarak kapalıdır. Ayarlar → Genel’den ⌃⌥⌘B veya ⌃⌥⌘C seçilirse panel her yerden açılıp kapanır; Erişilebilirlik izni gerekmez ve yalnızca o tuş birleşimini görür.
- **Diller.** İngilizce, Türkçe, Almanca, Fransızca ve İspanyolca; Healthy Battery macOS dilinizi izler, desteklenmeyen dillerde İngilizceye döner.
- **Özelleştirilebilir panel.** Bir karta uzun basın (veya sağ tık → Kartları düzenle): sürükleyerek sıralama, kart ekleme/çıkarma, kare/geniş seçimi ve batarya bilgileri kartında hangi satırların görüneceği.

### Planlanan; donanımda doğrulama gerekiyor

Bunlar arayüzde kilitli olarak ve **"Yakında"** etiketiyle görünür. Bunlar **çalışan özellikler değildir** — henüz bir şey yapmalarını beklemeyin:

- **Deşarj / otomatik deşarj** — bu donanımda bataryayı zorla deşarj etmenin doğrulanmış bir yolu yok.
- **Sailing** (bir aralıkta salınım) — bulunamayan çalışan bir duraklat/devam ettir (pause/resume) ilkeli gerektiriyor.
- **Isı koruması** — aynı duraklat/devam ettir ilkeli artı taze sıcaklık verisi gerektiriyor.
- **Kalibrasyon** — uzun süreli, geri alınabilir bir deşarj/şarj döngüsü; uygulanmadı.

## Gereksinimler

- **Yalnız Apple Silicon (arm64).**
- **macOS 27**'de, tek bir Mac modelinde test edildi. Diğer macOS sürümleri ve diğer Mac modelleri **test edilmedi** — çalışabilir, derlenemeyebilir veya sessizce hatalı davranabilir. Farklı bir modelde denerseniz lütfen Mac modelinizi ve macOS sürümünüzü belirterek bir issue açın.

## Kurulum

1. En son `.dmg` dosyasını [Releases](../../releases)'tan indirin. Yayınlanan sürümler Developer ID ile imzalanır ve Apple tarafından notarize edilir.
2. Açın ve `Healthy Battery.app` dosyasını Applications'a sürükleyin.
3. `./build.sh` ile kendiniz derlediğiniz bir kopya yalnızca geçici (ad-hoc) imzalıdır; ilk açılışta macOS uyarı verir — Sistem Ayarları → Gizlilik ve Güvenlik'ten izin verin.
4. Ayrıcalıklı bir yardımcı gerektiren bir özelliği (güç modu değiştirme veya MagSafe LED denetimi) ilk kullandığınızda, macOS o yardımcı için bir kez yönetici onayı ister. Healthy Battery parola saklamaz.

### Homebrew ile

[Healthy Battery Homebrew deposu](https://github.com/berkinefeavci/homebrew-cellkeep) yayında:

```sh
brew install --cask berkinefeavci/cellkeep/cellkeep
```

## Kaynaktan derleme

Xcode 27 gerektirir.

```sh
./check.sh
./build.sh
```

`check.sh` saf mantık test paketini çalıştırır. `build.sh` `.build/Cellkeep.app` dosyasını üretir.

## Kaldırma

Uygulama içinden (önerilen): Ayarlar → Genel → **"Healthy Battery'i kaldır"**. Tek bir yönetici onayıyla yardımcıları ve arka plan servislerini kaldırır, giriş öğesini siler, isterseniz macOS şarj sınırını %100'e döndürür (varsayılan açık) ve Healthy Battery verilerini siler (varsayılan kapalı). Ardından `Healthy Battery.app` veya eski `Cellkeep.app` dosyasını Çöp Sepeti'ne sürükleyin.

Elle kaldırma:

1. Önce Healthy Battery'ten çıkın ve Ayarlar'da "Oturum açılışında başlat"ı kapatın.
2. `Healthy Battery.app` veya eski `Cellkeep.app` dosyasını `/Applications`'tan Çöp Kutusu'na taşıyın.
3. Kuruluysa ayrıcalıklı yardımcıları kaldırın:
   ```sh
   sudo launchctl bootout system/io.github.berkinefeavci.cellkeep.powermode 2>/dev/null
   sudo launchctl bootout system/io.github.berkinefeavci.cellkeep.led 2>/dev/null
   sudo rm -f /Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.powermode.plist
   sudo rm -f /Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.led.plist
   sudo rm -f /Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode
   sudo rm -f /Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led
   ```
4. Healthy Battery kaldırılırken macOS şarj sınırınızı değiştirmez — sınır bir Healthy Battery süreci değil, bir macOS ayarıdır. İsterseniz Sistem Ayarları → Batarya'dan kendiniz kapatın.

## Nasıl çalışır ve sınırları

Healthy Battery, Apple'ın özel `PowerUI` çerçevesi (macOS'un kendi Batarya ayarlarının kullandığı aynı alt sistem) üzerinden okuma/yazma yapar ve az sayıda belgelenmiş, salt-okunur SMC anahtarı okur. Bu genel (public), kararlı bir API değildir: **bir macOS güncellemesi bunu önceden haber vermeden bozabilir** ve Healthy Battery'in bunu önceden tespit etmesinin bir yolu yoktur.

En önemli sınırlama: **bir şarj sınırı uygulamak, bağımsız bir geri-okumayla doğrulanmış bir yapılandırma yazmasıdır — fiziksel şarj akımının gerçekten o yüzdede durduğunun kanıtı değildir.** Healthy Battery, macOS'un istenen sınırı kabul ettiğini ve geri bildirdiğini doğruladı; ancak akımın gerçekten kesildiğini doğrulayan kontrollü bir fiziksel deney (pil hedefin üzerinde, şarj kablosu takılı, rakip denetleyiciler kapalı) henüz çalıştırılmadı. Sınırı "macOS ayarlandığını söylüyor" olarak görün, bir garanti olarak değil.

Her yerde aynı kural geçerlidir: bir değer ölçülemiyorsa Healthy Battery onu uydurmak yerine "—" gösterir. Görüntülemek için hiçbir ölçüm uydurulmaz veya aradeğerlemeyle üretilmez.

## Gizlilik

Healthy Battery tamamen Mac'inizde çalışır. Telemetri, analitik veya hesap yoktur. Tek ağ isteği, varsayılan olarak kapalı olan isteğe bağlı sürüm denetimidir; bkz. [PRIVACY.md](PRIVACY.md). Dışa aktardığınız tanılama raporları yalnızca seçtiğiniz yerel bir dosyaya kaydedilir ve hiçbir yere otomatik gönderilmez.

Bkz. [PRIVACY.md](PRIVACY.md).

## Katkıda bulunma

Issue ve pull request'ler için teşekkürler — build/test komutları ve donanıma yazan kod etrafındaki kurallar için [CONTRIBUTING.md](CONTRIBUTING.md) dosyasına bakın.

Healthy Battery işinize yarıyorsa: <!-- TODO: Buy Me a Coffee bağlantısı --> ☕

## Güvenlik

Bir güvenlik açığı mı buldunuz? Lütfen [SECURITY.md](SECURITY.md) dosyasına bakın — herkese açık bir issue açmayın.

## Lisans

MIT — bkz. [LICENSE](LICENSE).
