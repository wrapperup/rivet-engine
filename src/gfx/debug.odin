package gfx

import vk "vendor:vulkan"

object_type_of_handle :: proc($T: typeid) -> vk.ObjectType {
	//odinfmt: disable
	return \
		.BUFFER when T == vk.Buffer else
		.IMAGE when T == vk.Image else
		.IMAGE_VIEW when T == vk.ImageView else
		.COMMAND_POOL when T == vk.CommandPool else
		.DESCRIPTOR_POOL when T == vk.DescriptorPool else
		.DESCRIPTOR_SET_LAYOUT when T == vk.DescriptorSetLayout else
		.DESCRIPTOR_SET when T == vk.DescriptorSet else
		.FENCE when T == vk.Fence else
		.PIPELINE when T == vk.Pipeline else
		.PIPELINE_LAYOUT when T == vk.PipelineLayout else
		.SAMPLER when T == vk.Sampler else
		#panic("Handle type is not a valid resource")
	//odinfmt: enable
}

debug_set_object_name :: proc(handle: $T/u64, object_name: cstring) {
	if r_ctx.debug_messenger == 0 do return

	object_type := object_type_of_handle(T)

	name_info := vk.DebugUtilsObjectNameInfoEXT {
		sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
		objectType   = object_type,
		pObjectName  = object_name,
		objectHandle = u64(handle),
	}

	vk.SetDebugUtilsObjectNameEXT(r_ctx.device, &name_info)
}
