################################################################################
#
# cm762-wifi
#
################################################################################

CM762_WIFI_VERSION = 618c1c431d2e9bec61760d767bc161cee7d366ab
CM762_WIFI_SITE = https://github.com/morjaradat/ugreen-cm762-linux-driver/archive
CM762_WIFI_SOURCE = $(CM762_WIFI_VERSION).tar.gz
CM762_WIFI_LICENSE = GPL-2.0
CM762_WIFI_LICENSE_FILES = LICENSE
CM762_WIFI_DEPENDENCIES = host-kmod

CM762_WIFI_REPO_ROOT = $(abspath $(BR2_EXTERNAL_CM762_PATH)/../..)
CM762_WIFI_KERNEL_DIR = $(CM762_WIFI_REPO_ROOT)/linux-brain
CM762_WIFI_KERNEL_RELEASE = $(shell sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' $(CM762_WIFI_KERNEL_DIR)/include/generated/utsrelease.h)
CM762_WIFI_BUILD_RELEASE = $(shell $(MAKE) -s -C $(CM762_WIFI_KERNEL_DIR) kernelrelease)
CM762_WIFI_DRIVER_DIR = $(CM762_WIFI_SRCDIR)/aic8800_linux_driver/drivers/aic8800
# Match linux-brain's ARM EABI toolchain; Buildroot's internal GCC may be too old.
CM762_WIFI_CROSS_COMPILE = arm-linux-gnueabi-

define CM762_WIFI_BUILD_CMDS
	@test -s $(CM762_WIFI_KERNEL_DIR)/.config -a -s $(CM762_WIFI_KERNEL_DIR)/Module.symvers || \
		{ echo "Build linux-brain first (make docker-kernel)" >&2; exit 1; }
	# Rebuild host modpost with the Buildroot container's glibc. The kernel-tree
	# copy was built in Trixie and cannot run in this Bookworm build container.
	$(HOSTCC) -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer \
		-std=gnu11 -Wdeclaration-after-statement \
		-c $(CM762_WIFI_KERNEL_DIR)/scripts/mod/modpost.c -o $(CM762_WIFI_DIR)/modpost.o
	$(HOSTCC) -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer \
		-std=gnu11 -Wdeclaration-after-statement \
		-c $(CM762_WIFI_KERNEL_DIR)/scripts/mod/file2alias.c -o $(CM762_WIFI_DIR)/file2alias.o
	$(HOSTCC) -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer \
		-std=gnu11 -Wdeclaration-after-statement \
		-c $(CM762_WIFI_KERNEL_DIR)/scripts/mod/sumversion.c -o $(CM762_WIFI_DIR)/sumversion.o
	$(HOSTCC) -o $(CM762_WIFI_DIR)/modpost $(CM762_WIFI_DIR)/modpost.o \
		$(CM762_WIFI_DIR)/file2alias.o $(CM762_WIFI_DIR)/sumversion.o
	$(MAKE) -C $(CM762_WIFI_KERNEL_DIR) \
		M=$(CM762_WIFI_DRIVER_DIR) \
		ARCH=arm CROSS_COMPILE=$(CM762_WIFI_CROSS_COMPILE) \
		MODPOST=$(CM762_WIFI_DIR)/modpost modules
endef

define CM762_WIFI_INSTALL_TARGET_CMDS
	if [ "$(CM762_WIFI_BUILD_RELEASE)" != "$(CM762_WIFI_KERNEL_RELEASE)" ]; then \
		rm -f $(TARGET_DIR)/lib/modules/$(CM762_WIFI_BUILD_RELEASE)/extra/aic8800/aic_load_fw.ko \
			$(TARGET_DIR)/lib/modules/$(CM762_WIFI_BUILD_RELEASE)/extra/aic8800/aic8800_fdrv.ko; \
		rmdir $(TARGET_DIR)/lib/modules/$(CM762_WIFI_BUILD_RELEASE)/extra/aic8800 2>/dev/null || true; \
	fi
	$(INSTALL) -D -m 0644 $(CM762_WIFI_DRIVER_DIR)/aic_load_fw/aic_load_fw.ko \
		$(TARGET_DIR)/lib/modules/$(CM762_WIFI_KERNEL_RELEASE)/extra/aic8800/aic_load_fw.ko
	$(INSTALL) -D -m 0644 $(CM762_WIFI_DRIVER_DIR)/aic8800_fdrv/aic8800_fdrv.ko \
		$(TARGET_DIR)/lib/modules/$(CM762_WIFI_KERNEL_RELEASE)/extra/aic8800/aic8800_fdrv.ko
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/lib/firmware/aic8800D80
	cp -a $(CM762_WIFI_SRCDIR)/aic8800_linux_driver/fw/aic8800D80/. \
		$(TARGET_DIR)/lib/firmware/aic8800D80/
	$(INSTALL) -D -m 0755 $(CM762_WIFI_PKGDIR)/S40cm762-wifi \
		$(TARGET_DIR)/etc/init.d/S40cm762-wifi
	$(INSTALL) -D -m 0755 $(CM762_WIFI_PKGDIR)/S41cm762-network \
		$(TARGET_DIR)/etc/init.d/S41cm762-network
	$(HOST_DIR)/sbin/depmod -a -b $(TARGET_DIR) \
		-F $(CM762_WIFI_KERNEL_DIR)/System.map $(CM762_WIFI_KERNEL_RELEASE)
endef

$(eval $(generic-package))
