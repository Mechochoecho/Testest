#include "ir_tx.h"

#include "hardware/pwm.h"
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "pico/time.h"

static uint32_t s_pin;
static uint s_slice;
static uint s_chan;
static uint32_t s_cur_freq = 0;

void ir_tx_init(uint32_t gpio_pin) {
    s_pin = gpio_pin;
    gpio_set_function(gpio_pin, GPIO_FUNC_PWM);
    s_slice = pwm_gpio_to_slice_num(gpio_pin);
    s_chan = pwm_gpio_to_channel(gpio_pin);

    ir_tx_set_frequency(38000);
    pwm_set_enabled(s_slice, false);
}

void ir_tx_set_frequency(uint32_t freq_hz) {
    if (freq_hz == 0) freq_hz = 38000;
    if (freq_hz == s_cur_freq) return;

    uint32_t sys_clk = clock_get_hz(clk_sys);

    // wrapが16bitに収まるようclkdivを調整（125MHz sys_clkなら38kHzでdiv=1のままwrap≈3289で余裕）
    float divider = 1.0f;
    uint32_t wrap = (uint32_t)((float) sys_clk / (divider * (float) freq_hz));
    while (wrap > 65535 && divider < 255.0f) {
        divider *= 2.0f;
        wrap = (uint32_t)((float) sys_clk / (divider * (float) freq_hz));
    }
    if (wrap < 2) wrap = 2;

    pwm_set_clkdiv(s_slice, divider);
    pwm_set_wrap(s_slice, (uint16_t)(wrap - 1));
    // デューティ比 約33%（多くのIR LED/受信側の実測値と相性が良い一般的な値）
    pwm_set_chan_level(s_slice, s_chan, (uint16_t)(wrap / 3));

    s_cur_freq = freq_hz;
}

void ir_tx_send(const uint16_t *pattern_us, size_t count, uint32_t freq_hz) {
    if (count == 0) return;
    ir_tx_set_frequency(freq_hz);

    absolute_time_t target = get_absolute_time();

    for (size_t i = 0; i < count; i++) {
        bool is_mark = (i % 2) == 0;
        pwm_set_enabled(s_slice, is_mark);

        target = delayed_by_us(target, pattern_us[i]);
        busy_wait_until(target);
    }

    // 念のため必ず消灯して終了する
    pwm_set_enabled(s_slice, false);
}

void ir_tx_set_carrier(bool on) {
    pwm_set_enabled(s_slice, on);
}
