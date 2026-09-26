// Пример на чистом CMSIS (без драйверов): мигаем светодиодом Nucleo-F446RE (PA5).
// Регистры — F4 (RCC->AHB1ENR); для другого семейства поправьте тактирование порта.
#include <main.hpp>

// заголовок CMSIS выбранного чипа (define задаёт платформа, напр. "stm32f4xx.h")
#include STM32_DEVICE_HEADER

int main()
{
	// --- вариант на драйверах (нужен "drivers": true и раскомментированные includes в main.hpp) ---
	// System::Init();
	// ClockSystem::InitCalcPLL(180000000, ClockSystem::PLL_ClockSource::HSE, 8000000);
	// System::Enable_CYCCNT();
	// NUCLEO_LED.SetUp(PIN::TYPE::OUTPUT_PushPull);
	// uint32_t tick = System::GetTick();

	// --- вариант на CMSIS ---
	RCC->AHB1ENR |= RCC_AHB1ENR_GPIOAEN;                          // такты порта A
	GPIOA->MODER  = (GPIOA->MODER & ~(3U << (5 * 2))) | (1U << (5 * 2));   // PA5 — выход

	for(;;)
	{
		// if((System::GetTick() - tick) > 500) { NUCLEO_LED.TogglePin_BB(); tick = System::GetTick(); }

		GPIOA->ODR ^= 1U << 5;
		for(uint32_t i = 0; i < 1600000; i++){ __NOP(); }
	}
}

extern "C" void NMI_Handler(void)        { while(1){} }
extern "C" void HardFault_Handler(void)  { while(1){} }
extern "C" void MemManage_Handler(void)  { while(1){} }
extern "C" void BusFault_Handler(void)   { while(1){} }
extern "C" void UsageFault_Handler(void) { while(1){} }
