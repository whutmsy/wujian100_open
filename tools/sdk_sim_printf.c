/*
 * sdk_sim_printf.c - 让 SDK 程序在 QuestaSim 里能打印
 *
 * SDK 的 fputc() 走 csi_usart_putchar()，也就是真的 USI UART 寄存器，
 * 而 tb/virtual_counter.v 只认 "往 0x2001FFF0 写一个字节" 这种打印方式。
 * 链接时加 -Wl,--wrap=fputc，SDK 里所有 fputc 调用会转到 __wrap_fputc，
 * 于是 printf 输出就能出现在 transcript 里。
 *
 * 不要直接定义 fputc：libnewlib_wrap.a 是用 --whole-archive 链进来的，
 * 重名会撞车；--wrap 只改调用点，不动符号表。
 */
int __wrap_fputc(int ch, void *stream)
{
  (void)stream;
  *(volatile unsigned int *)0x2001FFF0u = (unsigned char)ch;
  return ch;
}
