---
title: "GNU Parallel を触れてみる"
featured_image: ""
date: 2025-02-16T11:00:00+09:00
draft: false
slug: '3fa121b4c7a971aacf564509a1077fb7'
categories: [ "linux" ]
tags: [ "linux", "cli" ]
---

気になっているけど避けてきた [GNU Parallel](https://www.gnu.org/software/parallel/) に入門してみます。
普段は [xargs](https://www.gnu.org/software/findutils/) の並列処理(-P max-procs, --max-procs=max-procs) を利用しているのですが、より高度な処理をしたくなる時に parallel の Exapmle を見るものの、難しそうと思い入門せずにいました。

しかし、蓋を開けてみれば、チュートリアルを含めドキュメントがきちんと整備されていました。
また、 [YouTube Playlist](http://www.youtube.com/playlist?list=PL284C9FF2488BC6D1) も公開されています。
動画の Part 1, Part 2 と、書籍 `GNU Parallel 2018` (公式サイトにソース及び PDF 有り) が分かりやすくお勧めです。

この記事では、これらのドキュメントに記載されている内容を元に一部を抜粋して記載しているので、記載されている内容に新規性は有りません。
私が普段から利用している xargs との比較も記載しますが、厳密に確認しておりませんので、細かい挙動の違いは有るかと思います。

<!--more-->

## 基本的な使い方と xargs との違い

parallel は xargs と同様に stdin からコマンドラインを生成することができます。

```
$ seq 1 3 | parallel echo
1
2
3
```

`:::` を用いると stdin の代わりにコマンドラインの引数として指定することもできます。

```
$ parallel echo ::: $(seq 1 3)
1
2
3
```

これは、 xargs で `-P` および `-n1` を用いた時に似ています。

```
$ seq 1 3 | xargs -P$(nproc) -n1 echo
1
2
3
```

これらの例では、 stdin で入力した順番に出力されていますが、当然ながら偶然です。
(今回のように単純な echo であれば順番が変わることは少いでしょうが...)

parallel でも、

```
$ seq 1 3 | parallel 'sleep $(( $RANDOM % 5 )); echo'
2
3
1
```

xargs でも同様です。
```
$ seq 1 3 | xargs -P$(nproc) -n1 bash -c 'sleep $(( $RANDOM % 5 )); echo $0'
2
1
3
```

ただし、 parallel では '--keep-order(-k)' オプションを用いることで、入力した順に出力できるので、入力と出力の順番が揃っている必要が有るケースでは便利です。
```
$ seq 1 3 | parallel -k 'sleep $(( $RANDOM % 5 )); echo'
1
2
3
```

同様のよく有る問題として、 stdout の出力が混ざることが有ります。

xargs で下記のように sleep の前後に `echo` を組み合わせると、出力が混ざることが分かります。
```
$ (echo 3; echo 2; echo 1) | \
pipe> xargs -I{} -P0 bash -c 'echo -n "start{}"; sleep {}; echo " end{}"'
start3start2start1 end1
 end2
 end3
```

一方で parallel は、標準で出力がグループ化されているため、出力が混ざりません。
```
$ (echo 3; echo 2; echo 1) | \
pipe> parallel 'echo -n "start{}"; sleep {}; echo " end{}"'
start1 end1
start2 end2
start3 end3
```

グループ化されているほうが便利なケースのほうが多いので便利ですが、 `-u` でグループ化を解除することもできます。
```
$ (echo 3; echo 2; echo 1) | \
pipe> parallel -u 'echo -n "start{}"; sleep {}; echo " end{}"'
start3start2start1 end1
 end2
 end3
```

説明を省きましたが、 xargs とは、 stdin から得たパラメータの位置指定に異なる点が有ります。
xargs では任意の場所に展開するために、 `-I{}` オプションを用いて '{}' の位置に展開しました。
parallel では同様のオプションを指定せずに '{}' を用いましたが、これは parallel で Input line として標準で定義されている為です。
parallel でも `-I` オプションを用いることで変更することができます。
'{}' の代わりに '{.}' '{/}' などの特殊な input line も有るので、後述します。

他にも、 shell の ';' やパイプの利用方法が xargs と異なります。
xargs ではシェルのパイプなどを利用したい場合は明示的に 'bash -c' などで起動していました。
```
$ seq 1 3 | xargs -P$(nproc) -n1 bash -c 'sleep $(( $RANDOM % 5 )); echo $0'
2
1
3
```

上記の例では、下記のコマンドラインに展開することでシェルの機能を利用しました。
```
bash -c 'sleep $(( $RANDOM % 5 )); echo $0' 1
bash -c 'sleep $(( $RANDOM % 5 )); echo $0' 2
bash -c 'sleep $(( $RANDOM % 5 )); echo $0' 3
```

明示的にシェル経由で実行しない場合はエラーとなります。
```
$ seq 1 3 | xargs -P$(nproc) -n1 'sleep $(( $RANDOM % 5 )); echo $0'
xargs: sleep $(( $RANDOM % 5 )); echo $0: そのようなファイルやディレクトリはありません
```

parallel では、下記のようにシェルを指定しませんでした。
```
$ echo $SHELL
/bin/zsh
$ seq 1 3 | parallel 'sleep $(( $RANDOM % 5 )); echo'
3
1
2
```

pstree を見ると zsh 経由でコマンドが実行されることで、シェルの機能が利用できていることが分かります。
```
$ pstree -a $(pgrep parallel)
parallel /usr/bin/parallel sleep $(( $RANDOM % 5 )); echo
  ├─zsh -c sleep $(( $RANDOM % 5 )); echo 1
  │   └─sleep 4
  ├─zsh -c sleep $(( $RANDOM % 5 )); echo 2
  │   └─sleep 4
  └─zsh -c sleep $(( $RANDOM % 5 )); echo 3
      └─sleep 1
```

このシェルは、 `$PARALLEL_SHELL` で指定できますが、未定義の場合は、 parallel を起動したシェル、 $SHELL 、 /bin/sh の順に決定できるまで探して利用されます。


## {} の扱い方

{} `Input line` は、便利な異なるバージョンが有り、この記事で紹介する代表的なものは下記のものです。

- {.}: 拡張子を除いたもの
- {/}: basename つまりファイル名
- {//}: dirname つまりディレクトリ名
- {/.}: {/} + {.} つまり拡張子を除いたファイル名

これらを利用すると、ファイルの形式変換で拡張子が変わる場合に指定が簡単になります。

例えば、次のように `ファイル形式/アーティスト名/アルバム名/トラック番号_曲名.拡張子` というパスになっている FLAC 形式の音楽ファイルが有ります。

```
$ ls
FLAC
$ find . -type f -name '*.flac' | shuf | head -5
./FLAC/真野恵里菜/FRIENDS/5_ラララ-ソソソ.flac
./FLAC/真野恵里菜/BEST FRIENDS/17_練馬Calling! (ボーナストラック).flac
./FLAC/Goose house/Milk/6_Pop Up!.flac
./FLAC/真野恵里菜/BEST FRIENDS/4_Love&Peace=パラダイス.flac
./FLAC/真野恵里菜/BEST FRIENDS/16_My Days for You.flac
```

これを全て mp3 に変更する場合、次のようなコマンドで ffmpeg による変換を並列処理できます。
なお、 `--eta` オプションを用いると、どれだけのコマンドが実行完了したか経過を確認することができます。
後述しますが、デフォルトでは例の通り、ジョブの並列数は CPU cores と同じになります。

```
$ cd FLAC
$ parallel --eta "mkdir -p ../mp3/{//}; ffmpeg -loglevel error -i {} -qscale:a 0 ../mp3/{.}.mp3" ::: **/*.flac

Computers / CPU cores / Max jobs to run
1:local / 16 / 16

Computer:jobs running/jobs completed/%of started jobs/Average seconds to complete
ETA: 0s Left: 0 AVG: 0.27s  local:0/64/100%/0.3s s
$ find ../mp3 -type f -name '*.mp3' | shuf | head -5
../mp3/真野恵里菜/BEST FRIENDS/11_青春のセレナーデ.mp3
../mp3/Goose house/Milk/7_L.I.P's.mp3
../mp3/真野恵里菜/FRIENDS/5_ラララ-ソソソ.mp3
../mp3/真野恵里菜/MORE FRIENDS/2_ごめん、話したかっただけ.mp3
../mp3/Goose house/Milk/8_笑ったままで.mp3
```

## 複数のパラメータ

parallel では複数のパラメータを組み合わせることができます。
例えば分かりやすいのは、下記の通り '1 2' と 'A B C' をクロスして 9 通りのコマンドラインを生成する方法です。
試験などで複数のパラメータを組み合わせる時に便利です。

```
% parallel echo ::: 1 2 ::: A B C
1 A
1 B
1 C
2 A
2 B
2 C
```

パラメータは '{1}' '{2}' のような形で、任意の位置に展開することができます。
```
$ parallel echo {2} {1} ::: 1 2 ::: A B C
A 1
B 1
C 1
A 2
B 2
C 2
```

`--link` を用いると、パラメータの '1 2 3' と 'A B C' がセットになり、次のようにコマンドラインを組み立てることができます。
```
$ parallel --link echo ::: 1 2 3 ::: A B C
1 A
2 B
3 C
```

また、パラメータは、一部を stdin に置き変えたり、ファイルに置き変えることも可能です。
下記の例では、 `-a` オプションで `-(stdin)` から `1 2 3` を読み、 同じく `-a` でファイル(プロセス置換)から `A B C` を読んでいます。

```
$ (echo 1; echo 2; echo 3) | parallel --link -a - -a <(echo A; echo B; echo C) echo
1 A
2 B
3 C
```

下記の例では、 `-a` オプションの代わりに `::::` を用いて `:::` と組み合わせた例です。
```
$ (echo 1; echo 2; echo 3) | parallel --link echo :::: - ::: A B C :::: <(echo X; echo Y; echo Z)
1 A X
2 B Y
3 C Z
```

この `--link` と複数のパラメータを使うと、前述の FLAC -> mp3 への変換で、変換前後の名前をリストで与えることができます。
下記の例では、 FLAC ファイルのリストである `src` と、それを元に一部のアーティスト名をアルファベット表記に変更した dst を用意しています。

```
$ find -type f -name '*.flac' > src
$ awk '{sub("\.\/真野恵里菜\/","./Erina Mano/",$0); sub("^\.","../mp3",$0); sub("\.flac$",".mp3",$0); print}' src > dst
$ paste src dst | shuf | head -5
./Goose house/Milk/7_L.I.P's.flac       ../mp3/Goose house/Milk/7_L.I.P's.mp3
./真野恵里菜/More Friends Over/10_風の薔薇～歩いて地図をつくった男のウタ～.flac ../mp3/Erina Mano/More Friends Over/10_風の薔薇～歩いて地図をつくった男のウタ～.mp3
./真野恵里菜/BEST FRIENDS/1_NEXT MY SELF.flac   ../mp3/Erina Mano/BEST FRIENDS/1_NEXT MY SELF.mp3
./真野恵里菜/FRIENDS/3_世界は サマー・パーティ.flac     ../mp3/Erina Mano/FRIENDS/3_世界は サマー・パーティ.mp3
./真野恵里菜/FRIENDS/11_おやすみなさい.flac     ../mp3/Erina Mano/FRIENDS/11_おやすみなさい.mp3
$ parallel --link "mkdir -p {2//}; ffmpeg -loglevel error -i {1} -qscale:a 0 {2}" :::: src dst
$ find ../mp3 -type f -name '*.mp3' | shuf | head -5
../mp3/Erina Mano/FRIENDS/7_ラッキーオーラ.mp3
../mp3/Goose house/Milk/5_Perfume.mp3
../mp3/Erina Mano/FRIENDS/11_おやすみなさい.mp3
../mp3/Erina Mano/More Friends Over/9_バンザイ！～人生はめっちゃワンダッホーッ！～.mp3
../mp3/Erina Mano/MORE FRIENDS/6_Tomorrow.mp3
```

## リモートホストを用いた分散処理

parallel の機能の 1 つとして、リモートホストを用いた分散処理が有ります。

'/data/music/FLAC' に FLAC 形式の音楽ファイルが有り、これを mp3 に ffmpeg で変換して '/data/musc/mp3' に保存する場合を例にします。
`/data` は NFS であり、ローカルマシン, sv1, sv2 の全てのノードで同じパスで参照できる状態です。
また、全てのマシンで parallel をインストールしてあります。

ここで新たに用いるオプションは `-S(--sshlogin)` と `--workdir` です。
`-S` は SSH ログインするマシンと、ローカルマシンを意味する ':' を列挙しています。
また今回は、相対パスを用いることから、 `--workdir` で全てのマシンの作業ディレクトリを統一します。
`--workdir` を指定しない場合、標準ではログインディレクトリ(~)が作業ディレクトリとなります。

```
$ cd /data/music/FLAC
$ find . -type f -name '*.flac' | wc -l
4981
$ time parallel --eta --workdir . -S :,sv1,sv2 "mkdir -p ../mp3/{//}; ffmpeg -loglevel error -i {} -qscale:a 0 ../mp3/{.}.mp3" ::: **/*.flac

Computers / CPU cores / Max jobs to run
1:local / 16 / 16
2:sv1 / 6 / 6
3:sv2 / 4 / 4

Computer:jobs running/jobs completed/%of started jobs/Average seconds to complete
ETA: 0s Left: 0 AVG: 0.23s  local:0/2756/55%/0.4s  sv1:0/1360/27%/0.8s  sv2:0/865/17%/1.3s
parallel --eta --workdir . -S :,sv1,sv2  ::: **/*.flac  14365.09s user 1455.21s system 1375% cpu 19:09.98 total
```

ネットワークファイルシステムが無い場合、 `--transferfile --return` オプションを組み合わせることで、処理対象のファイルをリモートコンピュータに rsync で複製し処理します。
`--cleanup` オプションを付けると、処理が終了後にリモートコンピュータからファイルを削除します。
これらをまとめた `--trc` オプションも存在します。

ローカルマシンのみに存在する `*.JPG` ファイルを png に変換する例です。

```
$ parallel --eta --transferfile {} --return {.}.png --cleanup -S :,sv1,sv2 "convert {} {.}.png" ::: *.JPG

Computers / CPU cores / Max jobs to run
1:local / 16 / 16
2:sv1 / 6 / 6
3:sv2 / 4 / 4

Computer:jobs running/jobs completed/%of started jobs/Average seconds to complete
ETA: 0s Left: 0 AVG: 0.23s  local:0/92/63%/0.4s  sv1:0/33/22%/1.1s  sv2:0/20/13%/1.8s
```

## job 数の制御

job 数の制御は `--jobs(-j)` により指定できます。
ジョブ数の指定の他、 '+N/-N' の形式で指定することで CPU スレッド数を基準に指定したり、 `N%` で CPU スレッドのパーセント指定が可能です。

例えば、各マシンの CPU スレッド -2 で処理をする場合は次のように `--jobs -2` となります。
```
$ parallel --jobs -2 --eta --transferfile {} --return {.}.png --cleanup -S :,sv1,sv2 "convert {} {.}.png" ::: *.JPG

Computers / CPU cores / Max jobs to run
1:local / 16 / 14
2:sv1 / 6 / 4
3:sv2 / 4 / 2

Computer:jobs running/jobs completed/%of started jobs/Average seconds to complete
ETA: 0s Left: 0 AVG: 0.26s  local:0/104/71%/0.4s  sv1:0/27/18%/1.6s  sv2:0/14/9%/3.0s
```

また、これらの値を記載したファイルを渡すことも可能で、ファイルを書き換えることでスロットルを変更することができます。
下記の例では、 10% で開始したため、各マシンのコア数のおおよそ 10% のジョブ数で開始することとなります。
```
$ echo 10% > jobs
$ parallel --jobs jobs --eta --transferfile {} --return {.}.png --cleanup -S :,sv1,sv2 "convert {} {.}.png" ::: *.JPG

Computers / CPU cores / Max jobs to run
1:local / 16 / 2
2:sv1 / 6 / 1
3:sv2 / 4 / 1

Computer:jobs running/jobs completed/%of started jobs/Average seconds to complete
ETA: 0s Left: 0 AVG: 0.34s  local:0/92/63%/0.6s  sv1:0/31/21%/1.7s  sv2:0/22/15%/2.5s
```

異なるターミナルから、ファイルを書き換えることでスロットルを変更することができます。
ただし、個々のジョブが完了したタイミングでファイルから再読み込みされるため、ジョブの処理時間が長い場合は即時の適用となりません。
```
$ echo 100% > jobs
```

## その他の機能

他にも多数の機能が有ります。
全てを紹介することは困難なので簡単なものだけ記載しますが、是非ドキュメントをご確認いただければと思います。

### 出力の構造化保存

`--results` を用いることで、 stdout, stderr などをファイルとして保存してくれます。

```
$ parallel --results dir echo ::: 1 2 3 ::: A B C
$ find dir -type f
dir/1/1/2/A/seq
dir/1/1/2/A/stdout
dir/1/1/2/A/stderr
dir/1/1/2/B/seq
dir/1/1/2/B/stdout
dir/1/1/2/B/stderr
dir/1/1/2/C/seq
dir/1/1/2/C/stdout
dir/1/1/2/C/stderr
dir/1/2/2/A/seq
dir/1/2/2/A/stdout
dir/1/2/2/A/stderr
dir/1/2/2/B/seq
dir/1/2/2/B/stdout
dir/1/2/2/B/stderr
dir/1/2/2/C/seq
dir/1/2/2/C/stdout
dir/1/2/2/C/stderr
dir/1/3/2/A/seq
dir/1/3/2/A/stdout
dir/1/3/2/A/stderr
dir/1/3/2/B/seq
dir/1/3/2/B/stdout
dir/1/3/2/B/stderr
dir/1/3/2/C/seq
dir/1/3/2/C/stdout
dir/1/3/2/C/stderr
$ find dir -type f -name "stdout" | xargs -n1 grep -H .
dir/1/1/2/A/stdout:1 A
dir/1/1/2/B/stdout:1 B
dir/1/1/2/C/stdout:1 C
dir/1/2/2/A/stdout:2 A
dir/1/2/2/B/stdout:2 B
dir/1/2/2/C/stdout:2 C
dir/1/3/2/A/stdout:3 A
dir/1/3/2/B/stdout:3 B
dir/1/3/2/C/stdout:3 C
```

### dry-run

`--dry-run` を用いることで、実行されるコマンドラインを確認できます。

```
$ parallel --dry-run echo ::: 1 2 3 ::: A B C
echo 1 A
echo 1 B
echo 1 C
echo 2 A
echo 2 B
echo 2 C
echo 3 A
echo 3 B
echo 3 C
```

### リソース制限

`--nice`,`--load`,`--noswap`,`--memfree`,`--limit [io|mem|load]` などのリソース制限機能があります。

`--nice` を用いると、 NICE 値が設定されます。
```
$ parallel --nice 19 "convert {} {.}.png" ::: *.JPG &
[1] 1470328
$ ps -la | awk 'NR==1 || /convert/'
F S   UID     PID    PPID  C PRI  NI ADDR SZ WCHAN  TTY          TIME CMD
0 R  1000 1470384 1470328 96  99  19 - 77714 -      pts/11   00:00:02 convert
0 R  1000 1470385 1470328 97  99  19 - 77714 -      pts/11   00:00:02 convert
0 R  1000 1470386 1470328 99  99  19 - 77714 -      pts/11   00:00:03 convert
0 R  1000 1470387 1470328 98  99  19 - 77714 -      pts/11   00:00:02 convert
0 R  1000 1470388 1470328 99  99  19 - 77714 -      pts/11   00:00:03 convert
0 R  1000 1470389 1470328 97  99  19 - 77714 -      pts/11   00:00:02 convert
0 R  1000 1470390 1470328 99  99  19 - 77714 -      pts/11   00:00:03 convert
0 R  1000 1470391 1470328 97  99  19 - 77714 -      pts/11   00:00:02 convert
0 R  1000 1470392 1470328 96  99  19 - 62139 -      pts/11   00:00:02 convert
0 R  1000 1470393 1470328 96  99  19 - 77714 -      pts/11   00:00:02 convert
0 R  1000 1470394 1470328 99  99  19 - 77714 -      pts/11   00:00:03 convert
0 R  1000 1470395 1470328 99  99  19 - 62139 -      pts/11   00:00:03 convert
0 R  1000 1470396 1470328 98  99  19 - 62139 -      pts/11   00:00:02 convert
0 R  1000 1470397 1470328 98  99  19 - 62139 -      pts/11   00:00:02 convert
0 R  1000 1470398 1470328 98  99  19 - 62139 -      pts/11   00:00:02 convert
0 R  1000 1470399 1470328 99  99  19 - 62139 -      pts/11   00:00:02 convert
```

`--load` を用いると、 CPU 負荷が指定された値より下回っていないとジョブが開始されません。
開始したジョブの負荷を制限するものでは無いことに留意が必要です。
例えば下記の通り `--load 5%` とした場合、別ターミナルで `yes > /dev/null` して CPU に 5% 以上の load をかけると次のジョブが開始しません。
`pkill yes` などで負荷が 5% より低くなった場合は、ジョブが次のジョブが開始されます。
前述の通り、開始されたジョブをコントロールするものでは無いので、筆者の環境では同時に 1 ~ 2 つのジョブが開始され CPU load は約 13 ~ 20% となりました。
```
$ parallel --eta --load 5% "convert {} {.}.png" ::: *.JPG
```

`--memfree` は `--load` のメモリ空き容量バージョンですが、こちらはメモリの空き容量が 50% 以下に低下した場合に若いジョブを終了するので、 `--retries` と合わせて利用するのが良いと思います。
