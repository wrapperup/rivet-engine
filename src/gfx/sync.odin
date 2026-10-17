package gfx

import vk "vendor:vulkan"

// Timeline semaphores only.
Semaphore :: distinct vk.Semaphore

Semaphore_Pair :: struct {
    sema: Semaphore,
    value: u64,
}

create_semaphore :: proc(init_value: u64) -> Semaphore {
    sema: vk.Semaphore

    result := vk.CreateSemaphore(
        r_ctx.device,
        &vk.SemaphoreCreateInfo{
            sType = .SEMAPHORE_CREATE_INFO,
            pNext = &vk.SemaphoreTypeCreateInfo {
                sType = .SEMAPHORE_TYPE_CREATE_INFO,
                semaphoreType = .TIMELINE,
                initialValue = init_value,
            },
        },
        nil,
        &sema,
    )

    vk_check(result)

    return Semaphore(sema)
}

destroy_semaphore :: proc(sema: Semaphore) {
    vk.DestroySemaphore(r_ctx.device, vk.Semaphore(sema), nil)
}

wait_semaphore :: proc(sema_pair: Semaphore_Pair) {
    sema := vk.Semaphore(sema_pair.sema)
    wait_value := sema_pair.value

    if sema == {} {
        // just no-op
        return
    }

    vk.WaitSemaphores(r_ctx.device, &{
        sType = .SEMAPHORE_WAIT_INFO,
        pSemaphores = &sema,
        pValues = &wait_value,
        semaphoreCount = 1,
    }, max(u64))
}

get_semaphore_value :: proc(sema: Semaphore) -> u64 {
    value: u64
    vk.GetSemaphoreCounterValue(r_ctx.device, vk.Semaphore(sema), &value)

    return value
}
