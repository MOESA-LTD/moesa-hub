# Dashboard grafikleri ve dialog/responsive düzeltmesi: kararlar ve açık noktalar

Dal: `feat/dashboard-charts` (taban `refactor/infrastructure`). Sahip isteği (21.11.2026): "istatistik verisi yok, chartlar ile zenginleştir, anlamlı güzel bir şey yap, diğer sorunları da gider"; sahip uyurken otonom yapıldı.

## Ne yapıldı

- **Dialog / responsive hatası**: ızgara sütunları ekran genişliğine (`md:`/`xl:`) göre seçiliyordu; dashboard dar veya boyutu değişen bir dialog'da açılınca 3 sütun sıkışıyordu. Artık dashboard'un kendi genişliği (CSS container query, `_charts.scss`) karar veriyor: 1 sütun, 40rem'den itibaren 2, 68rem'den itibaren 3, 112rem'den itibaren 4. "Düzenle" de ekran değil dashboard genişliğine bakıyor (`useElementSize`, 2 sütun = 640px).
- **Genel bakış şeridi** (kutuların üstünde, düzenlenmez): bekleyen kapılar, geciken görevler, açık siparişler, yoldaki sevkiyatlar, açık olaylar, yayındaki pazar hücreleri. Her biri yetkiye bağlı, listesine götürür, dikkat isteyen bağlam (gecikmiş, S1) ikon + kalın metinle.
- **7 grafik kutusu** (normal kutular gibi gizlenir, taşınır, genişletilir): kapı bekleme süresi (ekip/yönetim/müşteri yığılı sütun), günlere göre görevler (gecikmiş + bugün + 5 gün, kapıyı tutan ayrı), sipariş hattı (akış sırasıyla durumlar), durumlarına göre sevkiyatlar (zamanında / gecikmiş), şiddete göre açık olaylar (durum renkleri + ikon, kontrol altındakiler, yönetime bildirilmeyenler uyarısı), pazar kapsaması (yayında/hazırlanıyor/askıda, hedef çizgisi), ürün hazırlığı (imzalı spec ve uyum yüzdeleri).
- **Kutu kalitesi**: yüklenirken iskelet (eskiden veri gelmeden "Yok" görünüyordu, backlog Task 3 bulgusu kapandı), aynı satırdaki kutular eşit boy, ince çerçeve.

## Benim kararlarım (sahip gözden geçirir)

- Grafik kütüphanesi yok: düz HTML/CSS bileşenleri (`components/service-components/dashboard/charts/`). Kurulu ama kullanılmayan `chart.js@3.3.2` dokunulmadı; canvas yerine DOM, tema/dark mode ve dialog boyutlarıyla kendiliğinden uyumlu, ekran okuyucu için her grafikte gizli tablo var.
- Renkler: doğrulanmış kategorik paletin ilk 3 rengi (mavi, turuncu, aqua) ve sabit durum renkleri (kritik/ciddi/uyarı), `--viz-*` token'ları. Marka mavisi (`moesa`) yerine bu palet seçildi çünkü renk körlüğü doğrulaması bu sette yapılmış.
- Varsayılan düzende grafikler listelerin önünde. Kayıtlı düzeni olan kullanıcıda yeni kutular artık sona değil varsayılandaki yerine (kayıt sırasındaki en yakın önceki kutunun arkasına) giriyor; bu yüzden mevcut kullanıcılar grafikleri en üstte görür. `normalizeLayout` davranışı buna göre değişti.
- Görevlerin listesi olmadığı için "Geciken görevler" kutucuğu ve görev grafiği tıklanınca bir yere gitmez (mevcut görev kutuları gibi).
- Zaman serisi (trend) yok: view'lar yalnız anlık durum veriyor; trend için ayrı bir anlık görüntü tablosu gerekir.

## Onay bekleyen TR metinler

`tr/index.json` altında `dashboard.charts.*` ve `dashboard.overview.*` (ör. "Kapı bekleme süresi", "Günlere göre görevler", "Sipariş hattı", "Kapıyı tutan", "{n} olay henüz yönetime bildirilmedi", "Yayındaki pazar hücreleri"). Diğer diller İngilizce dolduruldu (`pnpm i18n-sync`).

## Doğrulama

vitest 1469/1469, `vue-tsc` temiz, lint 0 hata, build geçti. Local story seed verisiyle tarayıcıda kontrol: tam sayfa (4 sütun), dialog (2 sütun), dialog 420px (1 sütun, Düzenle gizli), açık ve koyu tema.
