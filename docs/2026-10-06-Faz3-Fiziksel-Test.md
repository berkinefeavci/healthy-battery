# Faz 3 fiziksel test protokolü (şarj durdurma helper'ı)

Bu testi insan çalıştırır. Kod yazan ajan hiçbir SMC yazması, kurulum ya da `sudo` yapmadı. Özellik arayüzde kilitli ("deneysel, fiziksel test bekliyor"); aşağıdaki test el ile kurulum ve gizli bir bayrakla yapılır.

Güvenlik ağı: helper her başlangıçta ve her çıkışta her şeyi serbest bırakır. Test boyunca elinizin altında şarj aleti ve ikinci bir terminal bulundurun. Acil çıkış (her zaman): `sudo launchctl bootout system/io.github.berkinefeavci.cellkeep.chargeinhibit` (SIGTERM gönderir, helper serbest bırakır).

Önkoşul: Mac17,8, macOS 26, pil %80-90, adaptör takılı, AlDente/batt gibi rakip uygulama KAPALI. `./build.sh` ile `.build/Cellkeep.app` hazır. SMC probe sonucu için `docs/2026-10-06-SMC-probe.md`: bu Mac'te `CHTE` yok, `CHIE` var; bu yüzden Bölüm B (şarj durdurma) yalnızca helper `C` komutunda ilk sayı 1 dönerse yapılır.

## 0. El ile kurulum (uygulama otomatik kurmaz)
```
APP=~/Depo/30-39_Aktif_Isler/hb-faz3/.build/Cellkeep.app
H=/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.chargeinhibit
L=io.github.berkinefeavci.cellkeep.chargeinhibit
sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$APP/Contents/Resources/CellkeepChargeInhibitHelper" "$H"
sudo codesign --verify --strict "$H"
sudo cp "$APP/../../Packaging/io.github.berkinefeavci.cellkeep.chargeinhibit.plist" /Library/LaunchDaemons/$L.plist
sudo chown root:wheel /Library/LaunchDaemons/$L.plist && sudo chmod 644 /Library/LaunchDaemons/$L.plist
sudo "$H" --authorize-uid $(id -u)
sudo launchctl bootstrap system /Library/LaunchDaemons/$L.plist
"$H" --version      # 1
```
(Plist yolu: repo'daki `Packaging/` klasörü; yol farklıysa düzeltin.)

Helper ile konuşma (yalnızca kendi kullanıcınız; uygulama bu satırları kullanır):
```
S=/var/run/io.github.berkinefeavci.cellkeep.chargeinhibit.sock
ask() { printf "$1" | nc -U $S; }      # ask 'C\n'
ask 'C\n'        # "0 <şarj-anahtarı-doğrulandı> <adaptör-anahtarı-doğrulandı>"
ask 'R\n'        # "0 <şarj-durduruldu> <adaptör-kesildi>"
ask 'S 1 0\n'    # şarjı durdur   (sonra 20 sn'de bir: ask 'H\n')
ask 'S 0 1\n'    # adaptörü kes (pilden çalış)
ask 'S 0 0\n'    # her şeyi serbest bırak
ask 'H\n'        # heartbeat
```
Yanıt kodları: 0 tamam, 2 geçersiz istek, 3 güvenlik kuralıyla reddedildi, 4 yazma/doğrulama başarısız (helper her şeyi serbest bıraktı), 5 bu Mac'te anahtar yok.

İzleme penceresi (ayrı terminal, tüm testlerde açık):
```
while true; do date +%T; pmset -g batt | sed -n 2p; ioreg -rn AppleSmartBattery | grep -E '"(ExternalConnected|IsCharging|InstantAmperage|NotChargingReason)"|NotChargingReason' | tr -s ' ' ; echo; sleep 5; done
```
Log: `sudo log show --last 5m --predicate 'process == "io.github.berkinefeavci.cellkeep.chargeinhibit"'` (helper stderr'e `charge-inhibit: released (<neden>)` yazar).

## A. Başlangıç ve yetki
1. `ask 'C\n'` ve `ask 'R\n'` çıktısını kaydedin. Beklenen: `R` -> `0 0 0`.
2. Başka kullanıcıdan/rootsuz farklı uid ile bağlanmak reddedilmeli: `sudo -u nobody sh -c "printf 'R\n' | nc -U $S"` -> `4`.
3. Geçersiz istek: `ask 'W CHIE 08\n'` -> `2`; `ask 'S 2 0\n'` -> `2`.

## B. Şarj durdurma (yalnızca `C` yanıtında ilk sayı 1 ise; bu Mac'te şu an 0 beklenir)
1. Pil %85 civarı, adaptör takılı, şarj oluyor. `ask 'S 1 0\n'` -> `0 1 0`.
2. 30 sn içinde: `InstantAmperage` ~0 (veya negatife yakın küçük), `IsCharging = No`, `NotChargingReason` != 0; adaptör bağlı kalır (`ExternalConnected = Yes`). Not alın.
3. `ask 'S 0 0\n'` -> 30 sn içinde şarj akımı geri gelmeli.
4. %85 -> %80 senaryosu: sınırı %80'e getirdiğinizde (Faz 4 olmadan elle) pil %80'e inene kadar bekleyin; `S 1 0` gönderin, akım 0 olmalı ve yüzde sabit kalmalı.

## C. Adaptörü kesme / deşarj (`CHIE`)
1. `ask 'S 0 1\n'` -> `0 0 1`. Beklenen: Mac pilden çalışır (`pmset -g batt` "Battery Power" ya da akım negatif). Menü çubuğu simgesi ve `ExternalConnected` değerini kaydedin (ExternalConnected `No` olabilir; helper "adaptör mevcut" bilgisini `AdapterDetails` dolu mu diye de kontrol eder. Bu davranışı not edin: kablo takılıyken `AdapterDetails` dolu kalıyor mu?).
2. `ask 'H\n'` komutunu 20 sn'de bir gönderin, 3 dakika pilden çalışmanın sürdüğünü doğrulayın.
3. `ask 'S 0 0\n'` -> adaptör geri gelir, 10 sn içinde `ExternalConnected = Yes`, şarj yeniden başlar.
4. Deşarj sonrası adaptör geri geliyor mu: C.1 ile pili %2-3 düşürün, sonra C.3; her şey normale dönmeli.

## D. Uygulama/heartbeat ölümü (watchdog, en önemli test)
1. `S 0 1\n` (ya da B anahtarı varsa `S 1 0\n`) gönderin, HEARTBEAT GÖNDERMEYİN.
2. Saati başlatın. En geç 60-62 sn içinde: `ask 'R\n'` -> `0 0 0`, adaptör/şarj geri. Log'da `released (watchdog)` görün. Süreyi kaydedin.
3. Heartbeat'li varyant: `S 0 1`, 20 sn'de bir `H`; sonra heartbeat'i kesin -> 60 sn sonra serbest kalmalı.
4. Uygulama öldürme: uygulamayı heartbeat sahibiyken `kill -9 <pid>` ile öldürün -> aynı sonuç (<= 60 sn). (Uygulama içi etkinleştirme yoksa bu adım terminaldeki `while true; do ask 'H\n'; sleep 20; done` döngüsünü Ctrl-C ile öldürerek yapılır.)
5. Helper'ı öldürün: `sudo kill -TERM $(pgrep -f chargeinhibit)` ve `sudo kill -9 ...` (KeepAlive yeniden başlatır; başlangıçta serbest bırakır). Beklenen: SIGTERM'de anında serbest; SIGKILL'de launchd yeniden başlatınca (<= 10 sn, ThrottleInterval) serbest.

## E. Kablo çıkar/tak
1. `S 0 1` (veya B varsa `S 1 0`) etkinken kabloyu çekin. Beklenen: 1-2 sn içinde `R` -> `0 0 0`, log'da `released (unplugged)`. Kabloyu geri takın: otomatik yeniden inhibit OLMAMALI (`R` hâlâ `0 0 0`).
2. `S` ile reddedilme: kablo çıkıkken `ask 'S 0 1\n'` -> `3`.

## F. Uyku / uyanma
1. `S 0 1` etkinken `pmset sleepnow`. 20 sn sonra uyandırın. Beklenen: `R` -> `0 0 0`, log'da `released (sleep)`; Mac uyurken pilin normal şarjla uyuduğunu kapak-ışığı/akım ile doğrulayın.
2. Uyanma sonrası otomatik yeniden inhibit olmamalı.
3. Kapağı kapat/aç (kapak uykusu) için tekrar edin.

## G. Güvenlik eşikleri
1. Pil >= %10 iken `S` kabul edilir; pil %9 ve altındayken `S` -> `3`. (Gerçek pille denemek için pili %10'a kadar boşaltmak gerekir; isterseniz sadece C.1 ile boşaltıp %10 altında `S 0 1` ve ardından otomatik serbest kalmayı gözleyin: log'da `released (low-battery)`.)
2. Kapatma: `S 0 1` etkinken `sudo shutdown -h now` yerine yeniden başlatın (`sudo shutdown -r now`). Açılışta `R` -> `0 0 0`; şarj/adaptör normal. Log: `released (shutdown)` ya da başlangıçta `released (start)`.
3. Rakip uygulama (AlDente/batt) çalışırken Faz 4 kilidi uygulama katmanındadır; helper tarafında test yok.

## H. Temizlik
```
sudo launchctl bootout system/$L
sudo rm -f "$H" /Library/LaunchDaemons/$L.plist
sudo rm -rf "/Library/Application Support/CellkeepChargeInhibit"
```
Sonunda `pmset -g batt` ve `ioreg -rn AppleSmartBattery | grep -E 'IsCharging|ExternalConnected'` ile normal duruma döndüğünü doğrulayın. Bir adım başarısız olursa DURUN, çıktıyı kaydedin; "geçti" demeden Faz 4 kilidi açılmaz.

## Sonuç tablosu (doldurulacak)
| Adım | Geçti/Kaldı | Ölçülen süre / akım | Not |
|---|---|---|---|
| A | | | |
| B (şarj) | | | bu Mac'te anahtar yoksa "uygulanamaz" |
| C (adaptör) | | | |
| D watchdog (<= 60 sn) | | | |
| E kablo | | | |
| F uyku | | | |
| G eşikler | | | |

Hata ayıklama yazılımı için gizli açma bayrağı (yalnızca test): `defaults write io.github.berkinefeavci.cellkeep debug.chargeInhibitUnlocked -bool YES` (kapatmak için `-bool NO`). Arayüzde açma yolu yoktur.
