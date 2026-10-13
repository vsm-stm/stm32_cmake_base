// Plain-CMSIS example (no drivers): blink the Nucleo-F446RE LED (PA5).
// Registers are F4 (RCC->AHB1ENR); adjust the port clock for another family.
#include <main.hpp>

// the selected chip's CMSIS header (the define is set by the platform, e.g. "stm32f4xx.h")
#include STM32_DEVICE_HEADER

int main()
{
	// --- drivers variant (needs "drivers": true and the includes in main.hpp uncommented) ---
	// System::Init();
	// constexpr auto clocks = ClockSystem::CalcPLL(180 * MHz, ClockSystem::PLL_ClockSource::HSE, 8 * MHz);
	// if (ClockSystem::Init<clocks>() != SysInitStatus::InitOK) System::DebugTrap("Clock init");
	// System::Enable_CYCCNT();
	// NUCLEO_LED.SetUp(PIN::TYPE::OUTPUT_PushPull);
	// uint32_t tick = System::GetTick();

	// --- plain CMSIS variant ---
	RCC->AHB1ENR |= RCC_AHB1ENR_GPIOAEN;                          // port A clock
	GPIOA->MODER  = (GPIOA->MODER & ~(3U << (5 * 2))) | (1U << (5 * 2));   // PA5 - output

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
