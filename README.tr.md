# Duet Bridge

**Apogee Duet 2 için klavye ses kontrolü (güncel macOS).**

[English](README.md)

Yeni Mac'lerde (macOS 26 yüklü Mac mini M4'te denendi) Duet 2'nin klavyeden ses
kontrolü çalışmıyor: macOS'un ses göstergesi hareket ediyor ama Duet'in analog
çıkışı değişmiyor. Resmi bir çözüm yok.

Duet Bridge küçük bir menü çubuğu uygulaması. Varsayılan çıkış Duet iken ses ve
sessiz tuşlarını yakalar ve değişikliği, Apogee Control 2'nin de konuştuğu arka
plan servisi **ApogeeGlue**'ya doğrudan gönderir. Donanım seviyesi ve Duet'in
OLED ekranı anında değişir; fiziksel düğmedeki değişiklikler de geri okunur.

> **Apogee Electronics ile bağlantılı değildir.** "Apogee", "Duet" ve "Apogee
> Control" sahiplerinin ticari markalarıdır. Bu, bağımsız bir birlikte
> çalışabilirlik aracıdır; Apogee'ye ait hiçbir kod ya da dosya içermez.
> Kullanım riski size aittir.

## Tuşlar

| Tuş | İşlev |
| --- | --- |
| Ses + / − | Hedef çıkışı (varsayılan Main Out) 2 dB değiştirir |
| ⇧⌥ + Ses + / − | 1 dB ince ayar |
| ⌃ + Ses + / − | Diğer çıkış (kulaklık) |
| Sessiz | Hedef çıkışı sessize alır / açar |
| ⌥ + Sessiz | Dim |

Varsayılan çıkış Duet değilse tuşlar macOS'a bırakılır. Menü çubuğundaki
hoparlör simgesinden hedef çıkış, adım büyüklüğü ve fiziksel düğme göstergesi
ayarlanır. Arayüz sistem diline göre Türkçe ya da İngilizce görünür.

## Gereksinimler

- Apogee Duet 2 ve kurulu Apogee Control 2 (Apogee Control 2 1.21.55 /
  ApogeeGlue 1.21.52 ile denendi).
- macOS 14 veya üstü; macOS 26.4, Apple Silicon üzerinde geliştirildi.
- Derlemek için Xcode ya da Xcode Command Line Tools (Swift 6).

## Kurulum

Hazır indirilebilir sürüm yok; uygulamayı kendi Mac'inizde derleyip
imzalarsınız.

```sh
git clone https://github.com/zgrkrky/duet-bridge.git
cd duet-bridge
Scripts/install.sh
```

Uygulama `~/Applications/Duet Bridge.app` olarak kurulur ve oturum açılışında
otomatik başlar.

İlk açılışta **Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik**
altında **Duet Bridge**'e izin verin. Uygulama izni birkaç saniye içinde kendisi
fark eder, yeniden başlatmak gerekmez.

### İzin verdim ama tuşlar çalışmıyor

Uygulama ad-hoc imzalı olduğu için macOS izni tam o ikiliye bağlar. Listede
eski bir derleme varsa anahtar açık görünür ama yeni sürüme uygulanmaz.
Sıfırlayıp yeniden izin verin:

```sh
tccutil reset Accessibility com.local.DuetBridge
```

Menü çubuğu menüsünde de aynı seçenek var. `Scripts/install.sh` ikili
değişmediyse yeniden imzalamaz; kodu değiştirip yeniden derlerseniz izni bir kez
daha vermeniz gerekir.

`~/Library/Logs/DuetBridge.log` dosyasında `event tap installed` satırını
arayın.

## Komut satırı

```sh
duet-bridge --status
duet-bridge --set  main -30
duet-bridge --step hp +2
duet-bridge --mute main [on|off|toggle]
duet-bridge --dim  main [on|off|toggle]
```

Servis yönetimi: `Scripts/duet-bridge-control.sh {install|start|stop|restart|status}`

## Nasıl çalışıyor

Apogee Control 2 donanımı kendisi sürmüyor; ApogeeGlue ile yerel bir TCP
bağlantısı (`127.0.0.1:53435`) üzerinden JUCE `ValueTree` eşitleme protokolüyle
konuşuyor. Duet Bridge aynı protokolü kullanıyor. Ayrıntılar:
[PROTOCOL.md](PROTOCOL.md).

Apogee bir güncellemede protokolü değiştirirse `duet-bridge --status`
bağlanamaz, menü çubuğu simgesi uyarı gösterir ve tuşlar normal macOS
davranışına döner.

## Lisans

[MIT](LICENSE)
