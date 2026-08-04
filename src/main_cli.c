// 自由に送受信・解析ができる、シリアル(USB CDC)ベースの汎用IRツール。
// android-ir-blasterのプロトコルとは無関係。Serial USB Terminal等から
// テキストコマンドで直接操作する。
//
// コマンド:
//   help
//   rx [timeout_ms]                受信を1回待つ(デフォルト15000ms)。RAWとNEC解読結果を表示
//   tx <freq_hz> <us1,us2,...>     任意のRAWパターンをそのまま送信(mark始まり)
//   nec <8桁hex>                   標準NEC形式(1byteごとLSBファースト)でエンコードして送信
//   necvariants <8桁hex>           ビット順/バイト順のバリエーションを2秒間隔で連続送信

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include "pico/stdlib.h"
#include "ir_tx.h"
#include "ir_rx.h"

#define GPIO_IR_TX 15
#define GPIO_IR_RX 16
#define LINE_MAX 512
#define PATTERN_MAX 1024

static uint16_t g_pattern[PATTERN_MAX];

// ---- NEC解読（sniffer機能の流用） ----

static bool nec_try_decode(const uint16_t *d, size_t n, uint32_t *addr, uint32_t *cmd) {
    if (n < 2 + 64) return false;
    if (d[0] < 8000 || d[0] > 10500) return false;
    if (d[1] < 4000 || d[1] > 5000) return false;

    uint32_t bits = 0;
    for (int i = 0; i < 32; i++) {
        uint16_t mark = d[2 + i * 2];
        uint16_t space = d[2 + i * 2 + 1];
        if (mark < 400 || mark > 800) return false;
        bool bit;
        if (space > 1300 && space < 2000) bit = true;
        else if (space > 350 && space < 800) bit = false;
        else return false;
        bits = (bits << 1) | (bit ? 1u : 0u);
    }
    *addr = (bits >> 16) & 0xFFFFu;
    *cmd = bits & 0xFFFFu;
    return true;
}

// ---- 受信コマンド ----

static void cmd_rx(uint32_t timeout_ms) {
    printf("受信待機中... (最大%lums、リモコンをVS1838Bに向けて押してください)\r\n", (unsigned long) timeout_ms);

    ir_rx_start(25000);
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);

    while (true) {
        ir_rx_poll_timeout();
        if (!ir_rx_is_capturing()) break;
        if (time_reached(deadline)) {
            ir_rx_stop();
            break;
        }
        sleep_ms(1);
    }

    uint16_t buf[IR_RX_BUF_LEN];
    size_t n = ir_rx_read(buf, IR_RX_BUF_LEN);

    if (n == 0) {
        printf("受信データなし(タイムアウト)\r\n");
        return;
    }

    printf("---- 受信 %u エントリ (確定までの無信号時間: %lu us) ----\r\n",
           (unsigned) n, (unsigned long) ir_rx_last_idle_gap_us());
    printf("RAW: ");
    for (size_t i = 0; i < n; i++) {
        printf("%u%s", (unsigned) buf[i], (i + 1 < n) ? "," : "");
    }
    printf("\r\n");

    uint32_t addr = 0, cmd = 0;
    if (nec_try_decode(buf, n, &addr, &cmd)) {
        printf("推定プロトコル: NEC addr=0x%04lX cmd=0x%04lX\r\n",
               (unsigned long) addr, (unsigned long) cmd);
    } else {
        printf("推定プロトコル: 不明\r\n");
    }
}

// ---- 生パターン送信コマンド ----

static size_t parse_csv_us(const char *s, uint16_t *out, size_t out_max) {
    size_t n = 0;
    while (*s && n < out_max) {
        char *end;
        long v = strtol(s, &end, 10);
        if (end == s) break;
        if (v < 0) v = 0;
        if (v > 0xFFFF) v = 0xFFFF;
        out[n++] = (uint16_t) v;
        s = end;
        while (*s == ',' || *s == ' ') s++;
    }
    return n;
}

static void cmd_tx(const char *args) {
    char freq_str[32];
    const char *sp = strchr(args, ' ');
    if (!sp) {
        printf("使い方: tx <freq_hz> <us1,us2,...>\r\n");
        return;
    }
    size_t flen = (size_t) (sp - args);
    if (flen >= sizeof(freq_str)) flen = sizeof(freq_str) - 1;
    memcpy(freq_str, args, flen);
    freq_str[flen] = '\0';

    uint32_t freq = (uint32_t) strtoul(freq_str, NULL, 10);
    if (freq == 0) freq = 38000;

    const char *pattern_str = sp + 1;
    size_t n = parse_csv_us(pattern_str, g_pattern, PATTERN_MAX);

    if (n == 0) {
        printf("パターンが空です\r\n");
        return;
    }

    printf("送信中: freq=%luHz entries=%u\r\n", (unsigned long) freq, (unsigned) n);
    ir_tx_send(g_pattern, n, freq);
    printf("送信完了\r\n");
}

// ---- NECエンコード（標準形式: 1byteごとLSBファースト） ----

static size_t nec_encode(uint32_t bytes32, bool lsb_first_per_byte, bool reverse_byte_order,
                          uint16_t *out, size_t out_max) {
    uint8_t b[4];
    b[0] = (uint8_t) (bytes32 >> 24);
    b[1] = (uint8_t) (bytes32 >> 16);
    b[2] = (uint8_t) (bytes32 >> 8);
    b[3] = (uint8_t) (bytes32 >> 0);

    uint8_t order[4];
    if (reverse_byte_order) {
        order[0] = b[3]; order[1] = b[2]; order[2] = b[1]; order[3] = b[0];
    } else {
        order[0] = b[0]; order[1] = b[1]; order[2] = b[2]; order[3] = b[3];
    }

    size_t n = 0;
    if (n < out_max) out[n++] = 9000; // leader mark
    if (n < out_max) out[n++] = 4500; // leader space

    for (int byte_i = 0; byte_i < 4; byte_i++) {
        uint8_t v = order[byte_i];
        for (int bit_i = 0; bit_i < 8; bit_i++) {
            int shift = lsb_first_per_byte ? bit_i : (7 - bit_i);
            bool bit = ((v >> shift) & 1) != 0;
            if (n < out_max) out[n++] = 562; // mark
            if (n < out_max) out[n++] = bit ? 1687 : 562; // space
        }
    }
    if (n < out_max) out[n++] = 562; // trailing mark
    return n;
}

static void cmd_nec(const char *hex) {
    uint32_t v = (uint32_t) strtoul(hex, NULL, 16);
    size_t n = nec_encode(v, true, false, g_pattern, PATTERN_MAX);
    printf("NEC標準形式(LSBファースト/byte順そのまま) を送信: 0x%08lX (entries=%u)\r\n",
           (unsigned long) v, (unsigned) n);
    ir_tx_send(g_pattern, n, 38000);
    printf("送信完了\r\n");
}

static void cmd_necvariants(const char *hex) {
    uint32_t v = (uint32_t) strtoul(hex, NULL, 16);

    struct { bool lsb; bool rev; const char *label; } variants[4] = {
        {true,  false, "LSBファースト / byte順そのまま (標準)"},
        {true,  true,  "LSBファースト / byte順逆転"},
        {false, false, "MSBファースト / byte順そのまま"},
        {false, true,  "MSBファースト / byte順逆転"},
    };

    for (int i = 0; i < 4; i++) {
        size_t n = nec_encode(v, variants[i].lsb, variants[i].rev, g_pattern, PATTERN_MAX);
        printf("[%d/4] %s を送信 (entries=%u)\r\n", i + 1, variants[i].label, (unsigned) n);
        ir_tx_send(g_pattern, n, 38000);
        sleep_ms(2000);
    }
    printf("全パターン送信完了\r\n");
}

static void cmd_help(void) {
    printf("コマンド一覧:\r\n");
    printf("  help                              このヘルプを表示\r\n");
    printf("  rx [timeout_ms]                   受信を1回待つ(デフォルト15000ms)\r\n");
    printf("  tx <freq_hz> <us1,us2,...>         任意のRAWパターンを送信(mark始まり)\r\n");
    printf("  nec <8桁hex>                       標準NEC形式で送信\r\n");
    printf("  necvariants <8桁hex>               ビット順/byte順を4パターン連続送信(2秒間隔)\r\n");
}

// ---- コマンドライン読み取り ----

static void process_line(char *line) {
    while (*line == ' ') line++;
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == '\n' || line[len - 1] == ' ')) {
        line[--len] = '\0';
    }
    if (len == 0) return;

    char *sp = strchr(line, ' ');
    if (sp) *sp = '\0';
    const char *args = sp ? sp + 1 : "";

    if (strcmp(line, "help") == 0) {
        cmd_help();
    } else if (strcmp(line, "rx") == 0) {
        uint32_t timeout_ms = (*args) ? (uint32_t) strtoul(args, NULL, 10) : 15000;
        cmd_rx(timeout_ms);
    } else if (strcmp(line, "tx") == 0) {
        cmd_tx(args);
    } else if (strcmp(line, "nec") == 0) {
        cmd_nec(args);
    } else if (strcmp(line, "necvariants") == 0) {
        cmd_necvariants(args);
    } else {
        printf("不明なコマンド: %s ('help'でコマンド一覧)\r\n", line);
    }
}

int main(void) {
    stdio_init_all();
    ir_tx_init(GPIO_IR_TX);
    ir_rx_init(GPIO_IR_RX);

    sleep_ms(3000);
    printf("\r\n=== Pico IR CLI ===\r\n");
    cmd_help();
    printf("\r\n> ");

    static char line[LINE_MAX];
    size_t pos = 0;

    while (true) {
        int c = getchar_timeout_us(10000);
        if (c == PICO_ERROR_TIMEOUT) continue;

        if (c == '\r' || c == '\n') {
            printf("\r\n");
            line[pos] = '\0';
            process_line(line);
            pos = 0;
            printf("\r\n> ");
        } else if (c == 8 || c == 127) { // backspace/delete
            if (pos > 0) {
                pos--;
                printf("\b \b");
            }
        } else if (pos < LINE_MAX - 1) {
            line[pos++] = (char) c;
            putchar(c);
        }
    }

    return 0;
}
