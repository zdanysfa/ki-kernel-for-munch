# Ki-Kernel for munch

Kernel pribadi untuk POCO F4 (munch): Linux 4.19, SM8250, basis LineageOS 22.2, dipakai pengguna root yang tetap peduli integrity. Spoof boleh.

Balas pakai Bahasa Indonesia.

## Cara kerja dengan pemilik repo

Pemilik repo melakukan vibe coding: kode ditulis lewat agent, dan permintaannya sering berupa "improve performance", "fix bug", atau sejenisnya. Karena itu:

- Terjemahkan permintaan umum menjadi akar masalah yang konkret, lalu tunjukkan buktinya.
- Jelaskan hasil dengan bahasa sederhana: apa yang berubah, apa yang sudah terbukti, dan apa yang belum.
- Jangan berasumsi pemilik repo bisa mendeteksi klaim yang salah. Lebih baik bilang "belum terbukti" daripada terdengar yakin.
- Pakai **ponytail**: akar masalah dulu, lalu perubahan terkecil yang benar. Tanpa abstraksi atau scaffolding untuk nanti.
- Pakai **graphify** untuk orientasi kode sebelum membaca atau grep massal (lihat bagian Graphify).

## Tujuan

Kernel ini **balance**: gaming oke, harian juga oke. Urutan saat bentrok:

1. Stabil: tidak hang, tidak mati saat idle, tidak bootloop.
2. Pemakaian harian: idle hemat, tidak panas, charging normal.
3. Performa game, lewat profil Performance dan Game Turbo.

Default harus tetap aman: profil Balanced, MGLRU mode 1, bypass charging mati, GPU Stock (OC + UV hanya kalau pengguna menekan Vol+). `tests/static/check_repo.sh` menjaga default ini. Tuning yang menaikkan performa dengan mengorbankan stabilitas atau idle ditolak.

## Build & verify

ROM utama: **HyperOS 1**, jadi target default CI adalah `miui`.

**Build kernel penuh selalu lewat GitHub Actions.** Laptop pemilik repo lemah, jadi jangan jalankan build penuh di lokal.

```bash
bash tests/run.sh                    # boleh di lokal: semua test host, tanpa build dan device
gh workflow run build-debug.yml      # debug, juga otomatis saat push ke main atau beta-test
gh workflow run build-debug.yml -f kasan=true   # debug + KASAN, risiko tidak boot lebih tinggi
gh workflow run build-release.yml    # release, juga otomatis saat push tag v*
bash tests/e2e/device_smoke.sh       # di HP lewat adb; IDLE_MINUTES=480 untuk uji semalaman
```

- `release`: kernel harian tanpa fitur debug.
- `debug`: full debug untuk mencari masalah, berat dan bukan untuk harian. Semua level dmesg termasuk `pr_debug`, kmemleak, lockdep, `SLUB_DEBUG`, `PAGE_OWNER`, panic saat task hang 240 detik. Artifact `symbols` berisi `vmlinux` untuk membaca backtrace.
- Kalau HP tidak boot dengan `debug`, kemungkinan pertama banjir log `dyndbg=+p`. Hapus dari `DEBUG_CMDLINE` di `build.sh`, lalu aktifkan saat runtime lewat `/sys/kernel/debug/dynamic_debug/control`.

Toolchain: ZyC Clang 16.0.6, rilisnya di `.github/workflows/_build.yml`.

## Test dan batasnya

- `tests/static/`: sintaks, default balance, Kconfig wajib.
- `tests/unit/` dan `cargo test --manifest-path ki_daemon/Cargo.toml`: logika WebUI dan daemon.
- `tests/e2e/verify_zip.sh`: bukti isi zip dan config build benar, bukan bukti kernel bisa boot.
- `tests/e2e/device_smoke.sh`: satu-satunya bukti di hardware asli. QEMU tidak bisa memboot image SM8250, jadi CI tidak bisa menggantikannya.

Compile per objek tidak membuktikan link. Sebelum menyebut sebuah perubahan beres, sebutkan lapisan mana yang benar-benar sudah dijalankan dan mana yang belum.

## Checklist saat fix bug atau improve

Cek yang relevan dengan perubahan. Kernel dan daemon punya bentuk masalah sendiri:

- **Deadlock/hang:** urutan lock, tidur saat pegang spinlock, `wait_event` tanpa timeout, reclaim yang menunggu selamanya. Task blocked tidak terlihat watchdog.
- **Timeout:** setiap tunggu ke hardware, firmware, atau proses luar harus punya batas dan jalur error.
- **OOM:** alokasi di jalur reclaim, ukuran buffer dari input, perilaku saat alokasi gagal.
- **Swap thrashing:** MGLRU, swappiness, kswapd. Perhatikan efek saat idle lama dan saat game berat.
- **Memory leak dan proses zombie:** jalur error wajib membebaskan resource. Proses anak `Command::spawn` di `ki_daemon` wajib di-reap.
- **Race condition:** IRQ vs worker, sysfs vs worker, suspend vs resume. Akses bersama pakai lock atau `READ_ONCE`/`WRITE_ONCE`.
- **Stale cache:** nilai terakhir yang disimpan tidak boleh menutupi sensor rusak, contohnya `last_valid_temp` di `bq27z561_fg_munch.c`. Tentukan kapan nilai itu kedaluwarsa.
- **Throttling:** thermal dan frekuensi harus pulih setelah suhu turun. Profil Performance tidak boleh mematikan perlindungan panas tanpa batas.
- **Health check:** status daemon dan kernel harus bisa dibaca dari luar: `daemon.status`, node sysfs, `device_smoke.sh`.
- **Log & monitoring:** error harus meninggalkan jejak di dmesg atau pstore, tanpa spam di jalur panas pada build release.
- **JSON/payload:** data dari file config, WebUI, dan output `ksu.exec` adalah input tidak tepercaya. Validasi format dan ukurannya.
- **Unsanitized query versi shell:** nilai dari config atau pengguna tidak boleh masuk shell tanpa `shellQuote` di `app.js` atau `is_valid_package` di daemon.
- **CI/CD:** perubahan logika wajib punya test di `tests/` atau `cargo test`, dan workflow harus tetap hijau.
- **Disk I/O:** hindari tulis berkala yang membangunkan UFS saat idle, dan jangan melewati sync sebelum suspend.

## Gotcha

- **Dependensi root.** `fetch_deps.sh` selalu mengambil commit terbaru BakaSU, NoMount, dan Baseband-guard, jadi build bisa gagal saat upstream berubah. Commit yang dipakai tercatat di artifact `deps-versions.txt`. `drivers/kernelsu`, `fs/nomount`, dan `security/baseband-guard` adalah symlink yang kosong sebelum script itu dijalankan.
- **Multi manager.** Harus mendukung FinaSU, MidoriSU, KowSU, KSUN, RKSU, KSU, dan BakaSU. BakaSU hanya mengenali dirinya, KSU, dan KowSU, jadi `fetch_deps.sh` menambahkan sertifikat KSUN, RKSU, FinaSU, dan MidoriSU ke `kernel/manager/apk_sign.c`. Jangan pernah mem-bypass cek tanda tangan: aplikasi apa pun bisa jadi manager root. Kalau sebuah manager ganti kunci, ambil ulang dari APK rilisnya. Tanda tangan diterima bukan jaminan semua fitur manager jalan, sebab UAPI tiap fork bisa beda.
- **`build.sh` mengotori tree.** Script itu menimpa `CONFIG_LOCALVERSION` di defconfig dan `kona-v2-gpu.dtsi`. Jangan ikut commit hasilnya.
- **Display ada dua salinan.** Perbaikan di `techpack/display/msm` hampir selalu perlu juga di `techpack/display/msm-miui`. Compile keduanya: AOSP memakai yang pertama, MIUI (`CONFIG_XIAOMI_MIUI`) yang kedua.
- **`anykernel.sh` ada dua salinan.** Yang di root dan di `anykernel_template/` harus identik, dan yang masuk zip adalah versi template.
- **`scripts/config` diam saat simbol salah.** Nama Kconfig yang salah diabaikan tanpa error. Test static memeriksa simbol di `apply_debug_config`.
- **`.gitignore` mengabaikan `.*`.** `.github/` dikecualikan secara eksplisit.
- **`ki_optimizer_module/bin/ki_daemon` adalah prebuilt.** Mengubah `ki_daemon/src/main.rs` tidak mengubah binary ini sampai dibuild ulang untuk aarch64.
- **SELinux di-spoof.** `getenforce` tidak bisa dipakai sebagai bukti status SELinux yang sebenarnya.
- **`/proc/config.gz` di-spoof.** `kernel/Makefile` menanam `munch_stock-defconfig`, bukan config build, jadi ikconfig dan `extract-ikconfig` tidak bisa dipakai sebagai bukti. Config asli ada di `out/.config` dan artifact `symbols`.
- **Mati saat idle belum terbukti akar masalahnya.** Bukti dicari di `/sys/fs/pstore` setelah build debug. Jangan menulis "sudah fix" tanpa log dari device.

## Graphify

Untuk pertanyaan soal kode, jalankan `graphify query "<pertanyaan>"` dulu kalau `graphify-out/graph.json` ada, lalu `graphify path` atau `graphify explain`. Graph hanya peta struktur, dan edge `INFERRED` wajib dicek ke kode asli. `graphify-out/` tidak di-commit.

## Git

- Jangan commit atau push tanpa diminta. Merge ke branch default butuh persetujuan per kasus.
- Dilarang ada atribusi AI di commit, PR, issue, atau komentar: tidak ada `Co-Authored-By: Claude`, `Generated with Claude Code`, atau link sesi.
- Identitas commit tetap dari git global. Jangan mengubah tanggal commit.
