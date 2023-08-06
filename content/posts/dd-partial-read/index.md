---
title: "ddコマンドによるpartial readとデータ破損について"
featured_image: ""
date: 2021-06-20T19:00:00+09:00
draft: false
slug: 'b2f8ec0fe0a37c9dcd1cc4d909e72652'
categories: [ "code" ]
tags: [ "linux" , "code" ]
---

dd(1) はブロックデバイスを読み書きする際に非常に便利で、ストレージ装置のバックアップやクローン作成、データ消去などに利用します。その際に(i)bs=[bytes]とcount=[count]で読み込みブロックサイズと個数を指定できますが、ddコマンドと、内部で利用される read(2) の特性を把握しておかなければ、部分的な読み出しにより、期待した出力が得られない事があります。通常は警告が表示されますが、バックアップやクローン用途で使っておりスクリプトで実行している場合、気が付かなければデータ破損に繋がります。

ここではデータ破損と表現していますが、入力と出力がブロック単位で同一とならない事象が発生するものであり、入力データが破損するものでは有りません。

<!--more-->

テスト環境
```
[yoshihisa@desktop ~]$ dd --version
dd (coreutils) 8.32
Copyright (C) 2020 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

作者 Paul Rubin、 David MacKenzie、および Stuart Kemp。
[yoshihisa@desktop ~]$ cat /etc/os-release
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://archlinux.org/"
DOCUMENTATION_URL="https://wiki.archlinux.org/"
SUPPORT_URL="https://bbs.archlinux.org/"
BUG_REPORT_URL="https://bugs.archlinux.org/"
LOGO=archlinux
[yoshihisa@desktop ~]$ uname -r
5.12.10-arch1-1
```

## partial read
partial read (部分読み出し)は、(i)bsで指定されたサイズ(デフォルト512byte)を全て読まないことによって発生する問題です。通常は下記のようにstderrに警告が表示されます。
```
[yoshihisa@desktop ~]$ dd if=/dev/urandom of=file bs=4M count=100
41+0 レコード入力
41+0 レコード出力
171966464 bytes (172 MB, 164 MiB) copied, 1.96944 s, 87.3 MB/s
dd: warning: partial read (2854848 bytes); suggest iflag=fullblock
```
上記は /dev/urandom からブロックサイズ4MiB単位で100回入力し、通常ファイルfileに出力しています。  
別ターミナルからddプロセスに対し SIGUSR1 を送出しており、途中経過が表示されると同時にpartial readが発生し、最終行で警告とサジェストが表示されています。この警告及びサジェストはddの他出力と同様にstderrに出力されますが、初回のみ表示されます。
```
99+1 レコード入力
99+1 レコード出力
418090944 bytes (418 MB, 399 MiB) copied, 4.75245 s, 88.0 MB/s
[yoshihisa@desktop ~]$
```
最終的な出力は上記となり、完全な99ブロックと、不完全な1ブロックを入力し出力した事を示します。また複製した容量がMBとMiBで表示されていますが、418090944 bytes は 398.72... MiBとなっており、400MiBでは無いことから不完全な出力となっている事が分かります。これが dd における partial read です。

なお、partial read が発生した場合でも、$?は0となるので戻り値で判別はできません。

## なぜ発生するか
ddは、(i)bsサイズをread(2)に指定して読み込む動作をcount回だけ繰り返すことで動作します。

```
read(2)
ssize_t read(int fd, void *buf, size_t count);
  fd    ... 読み込むファイルディスクリプタ
  *buf  ... 読み込んだデータを書き込むバッファ
  count ... 読み込むサイズ(bytes)

  戻り値は、実際に読み込んだサイズ(bytes)
```
他のシステムコールと同様にread(2)は、指定されたサイズ(count)を全て読み切る保証が無いことに注意する必要が有ります。countは最大読み込み容量としてsizeof(\*buf)を指定し、\*bufに対するオーバーフローを発生させない為に用います。実装においては、実際に読み込んだサイズが戻り値として返されるので、それだけ実際の読み込みが行われたと判断し、同じだけ\*bufから読み込み結果を得られます。またファイルオフセットも同数だけseekされます。ddは、read(2)がcountより低い値を返却した場合に不完全な1ブロックとマークし警告するのみで、残り(count-戻り値)を改めて読み直すことはしません。

これにより、countが指定されている場合は不十分な出力ファイルが生成される事が有ります。例えばibs=4M count=100 の場合、4Mのread(2)を100回実行します。100回のうち、1回だけ2MiBの読み込みでread(2)が戻ってしまうと、ifに指定したファイルの先頭から398MiBだけ複製する事となり、末尾の2MiBが欠落します。

count指定が無い場合は上記のような欠落は発生しません。例えばsizeが512byteで有る場合、途中でread(2)が450byteだけ返したとしても、続きから512byteを読もうとします。末尾まで繰り返し読み切るため、入力と出力で差が発生することは有りません。しかしpartial readの後は読み込みデバイスの境界がズレることでパフォーマンス低下が発生する可能性に注意する必要が有ります。

## read(2)が全て読み切らないケース
read(2)が指定されたcount(bytes)だけ読み切らない代表的な理由は次のものが有ります。(他にも有ります)

1. fdのEOFにぶつかった。
1. 遅いデバイスからの読み出しでI/Oでブロックされている間にシグナルハンドラが動作した。なおここでの遅いデバイスはローカルディスクを含まない。
    1. シグナルハンドラからreadに処理が戻った時点で、まだ何も読み出せてない場合、戻り値として負数をセットし errno == EINTR がセットされる。
    1. シグナルハンドラからreadに処理が戻った時点で、既に読み込んだ内容が有る場合、指定されたサイズ(count)を読み切っていなくても、既に読み込んだサイズを戻す。

1 のケースは想像しやすい事象で、続けてread(2)を発行すれば 0 が戻ってくるはずです。当然ながら今回の事象の原因とはなりません。

2-2 のケースが今回の事象の原因となります。

## 対処方法
対処方法はサジェストされている通り、iflag=fullblock を用いることです。このオプションを用いると、read(2)がcount(bytes)を全て読み切らずに戻った場合は、残りのサイズ(=count-戻り値)をread(2)のcountに改めて指定して残りを読みます。
```
[yoshihisa@desktop ~]$ dd if=/dev/urandom of=file bs=4M count=100 iflag=fullblock
```

## コード
https://github.com/coreutils/coreutils/blob/v8.32/src/dd.c

上記のコードを参考に、該当する箇所を確認します。

### コマンドライン
```
1640   iread_fnc = ((input_flags & O_FULLBLOCK)
1641                ? iread_fullblock
1642                : iread);
1643   input_flags &= ~O_FULLBLOCK;
```
https://github.com/coreutils/coreutils/blob/v8.32/src/dd.c#L1640-L1643

上記がコマンドラインをパースしているうち、iflag=fullblock を処理している部分です。iflagにfullblockが指定されている場合は、iread\_fncとしてiread\_fullblockを、オプションが指定されていない場合はireadを指定しています。

### iread
https://github.com/coreutils/coreutils/blob/v8.32/src/dd.c#L1121-L1169

```
1128   ssize_t nread;
1129   static ssize_t prev_nread;

1134       nread = read (fd, buf, size);

1151   if (0 < nread && warn_partial_read)
1152     {
1153       if (0 < prev_nread && prev_nread < size)
1154         {
1155           uintmax_t prev = prev_nread;
1156           if (status_level != STATUS_NONE)
1157             error (0, 0, ngettext (("warning: partial read (%"PRIuMAX" byte); "
1158                                     "suggest iflag=fullblock"),
1159                                    ("warning: partial read (%"PRIuMAX" bytes); "
1160                                     "suggest iflag=fullblock"),
1161                                    select_plural (prev)),
1162                    prev);
1163           warn_partial_read = false;
1164         }
1165     }
1166
1167   prev_nread = nread;
```

上記が、 iread のうち、必要な部分のみを抜粋したものです。

L1134 の read(2) で戻ってきた値が 0 < nread < size となるケースは、先に上げた 1. 途中でfdのEOFにぶつかった もしくは 2-2. シグナルハンドラから戻った時点で既に読み込んだ内容が有った ケースに該当します。

L1151 の条件に存在する warn\_partial\_read は、partial readが発生した場合に警告を表示する為のフラグで、初期値はtrueです。そのためこの条件は、read(2)によって1でも読み込まれていればtrueとなります。

L1153 の条件に存在する prev\_nread は前回のnreadで、これが 0 < prev\_nread < size であった時、つまりshort readであった場合にtrueとなります。その場合にpartial readの警告を表示し、warn\_partial\_readをfalseにすることで、最初の1回のみ表示します。

L1151 と L1153 の条件から、これらの条件を満たすのは、前回のread(2)がshort readであり、今回のread(2)が1でも読み込めた場合となります。つまり、前回のread(2)がshort readで有った場合に警告を表示する事となります。これは、read(2)のshort readが発生した際に、fdのEOFに到達した為に発生したshort readで有るか否かを、次のread(2)の戻り値で判定する為です。次のread(2)の戻り値が0であれば、fdのEOFに到達した事によるshort readで有り問題有りませんが、1以上で有ればEOFに到達した以外によるshort readなので、警告を表示する事となります。


### iread\_fullblock
https://github.com/coreutils/coreutils/blob/v8.32/src/dd.c#L1171-L1190
```
1171 /* Wrapper around iread function to accumulate full blocks.  */
1172 static ssize_t
1173 iread_fullblock (int fd, char *buf, size_t size)
1174 {
1175   ssize_t nread = 0;
1176
1177   while (0 < size)
1178     {
1179       ssize_t ncurr = iread (fd, buf, size);
1180       if (ncurr < 0)
1181         return ncurr;
1182       if (ncurr == 0)
1183         break;
1184       nread += ncurr;
1185       buf   += ncurr;
1186       size  -= ncurr;
1187     }
1188
1189   return nread;
1190 }
```
iflag=fullblock とした場合には、 iread ラップの iread\_fullblock が用いられます。これは iread を呼び size に満たない戻り値だった場合に、size を満たすまで残りを読もうとします。
