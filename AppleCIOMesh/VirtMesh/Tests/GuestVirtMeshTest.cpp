// Copyright © 2025 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

#include "../Guest/AppleVirtMesh/Interfaces.h"
#include "../Utils/Message.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <algorithm>
#include <expected>
#include <gtest/gtest.h>
#include <iostream>
#include <mach/mach_error.h>
#include <memory>
#include <string_view>
#include <unistd.h>
#include <unordered_map>

#define kVirtMeshDriverClassName "AppleVirtMeshDriver"

constexpr uint64_t kMaxBlockSize = 16 * 1024 * 1024;
constexpr uint64_t kMaxBreakdown = 8;

using namespace VirtMesh::Guest::Mesh;

class ClientConnect
{
  public:
	io_connect_t   connect_ = IO_OBJECT_NULL;
	MeshClientType type_    = MeshClientType::MainClient;
	io_service_t   service_ = IO_OBJECT_NULL;

	ClientConnect(io_service_t service, MeshClientType clientType) : connect_(IO_OBJECT_NULL), service_(service), type_(clientType)
	{
	}

	~ClientConnect()
	{
		if (connect_ != IO_OBJECT_NULL) {
			IOServiceClose(connect_);
			connect_ = IO_OBJECT_NULL;
		}
	}

	void
	connect()
	{
		auto type = static_cast<uint32_t>(type_);
		auto res  = IOServiceOpen(service_, mach_task_self(), type, &connect_);
		ASSERT_EQ(res, KERN_SUCCESS) << "Failed to connect to service with user client type [" << type << "], error: ["
		                             << mach_error_string(res) << "] [0x" << std::hex << res << "]";
	}

	kern_return_t
	Call(mach_port_t selector, const void * inputStruct, size_t inputSize, void * outputStruct, size_t * outputSize) const
	{
		return IOConnectCallStructMethod(connect_, selector, inputStruct, inputSize, outputStruct, outputSize);
	}

	kern_return_t
	Call(mach_port_t selector, const void * inputStruct, size_t inputSize) const
	{
		return Call(selector, inputStruct, inputSize, nullptr, 0);
	}

	kern_return_t
	Call(mach_port_t selector, size_t outputSize, void * outputStruct) const
	{
		auto size = outputSize;
		auto res  = Call(selector, nullptr, 0, outputStruct, &size);
		EXPECT_EQ(outputSize, size);
		return res;
	}

	kern_return_t
	Call(mach_port_t selector) const
	{
		return IOConnectCallStructMethod(connect_, selector, nullptr, 0, nullptr, nullptr);
	}

	kern_return_t
	Call(mach_port_t selector, mach_port_t wake_port, uint64_t * reference, uint32_t referenceCnt) const
	{
		std::cout << "Calling [" << __FUNCTION__ << "]: wake_port: 0x" << std::hex << wake_port << std::endl;
		return IOConnectCallAsyncMethod(
		    connect_,
		    selector,
		    wake_port,
		    reference,
		    referenceCnt,
		    nullptr,
		    0,
		    nullptr,
		    0,
		    nullptr,
		    nullptr,
		    nullptr,
		    nullptr
		);
	}

	kern_return_t
	Trap(mach_port_t selector) const
	{
		return IOConnectTrap0(connect_, selector);
	}

	kern_return_t
	Trap(mach_port_t selector, uintptr_t arg0) const
	{
		return IOConnectTrap1(connect_, selector, arg0);
	}

	kern_return_t
	Trap(mach_port_t selector, uintptr_t arg0, uintptr_t arg1) const
	{
		return IOConnectTrap2(connect_, selector, arg0, arg1);
	}

	kern_return_t
	Trap(mach_port_t selector, uintptr_t arg0, uintptr_t arg1, uintptr_t arg2) const
	{
		return IOConnectTrap3(connect_, selector, arg0, arg1, arg2);
	}

	kern_return_t
	Trap(mach_port_t selector, uintptr_t arg0, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3) const
	{
		return IOConnectTrap4(connect_, selector, arg0, arg1, arg2, arg3);
	}

	kern_return_t
	Trap(mach_port_t selector, uintptr_t arg0, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t arg4) const
	{
		return IOConnectTrap5(connect_, selector, arg0, arg1, arg2, arg3, arg4);
	}

	kern_return_t
	Trap(mach_port_t selector, uintptr_t arg0, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t arg4, uintptr_t arg5) const
	{
		return IOConnectTrap6(connect_, selector, arg0, arg1, arg2, arg3, arg4, arg5);
	}

	void
	ExpectUnimplemented(mach_port_t selector) const
	{
		auto res = Call(selector, nullptr, 0, nullptr, nullptr);
		ASSERT_TRUE(res == kIOReturnUnsupported || res == kIOReturnBadArgument)
		    << "Expect unsupported but got: 0x" << std::hex << res << ": " << mach_error_string(res);
	}

	void
	ExpectUnimplementedTrap(mach_port_t selector) const
	{
		auto res = Trap(selector);
		ASSERT_TRUE(res == kIOReturnUnsupported || res == kIOReturnBadArgument)
		    << "Expect unsupported but got: 0x" << std::hex << res << ": " << mach_error_string(res);
	}

	void
	ExpectBadArgument(mach_port_t selector) const
	{
		auto res = Call(selector, nullptr, 0, nullptr, nullptr);
		ASSERT_EQ(res, kIOReturnBadArgument) << "Expect unsupported but got: 0x" << std::hex << res << ": "
		                                     << mach_error_string(res);
	}
};

class GuestVirtCIOMeshMockTest : public ::testing::Test
{
  protected:
	io_connect_t                                                         connect_         = IO_OBJECT_NULL;
	std::string_view                                                     serviceClassName = kVirtMeshDriverClassName;
	std::shared_ptr<ClientConnect>                                       main_client_;
	std::shared_ptr<ClientConnect>                                       config_client_;
	std::unordered_map<MainClient::BufferId, std::unique_ptr<uint8_t[]>> buffers_;
	ConfigClient::NodeId                                                 leader_node_id_ = ConfigClient::NodeId(0);

	void
	SetUp() override
	{
		// Get the service
		io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClassName.data()));
		ASSERT_NE(service, IO_OBJECT_NULL) << "Failed to find service";

		// Open connections to the service
		main_client_   = std::make_shared<ClientConnect>(service, MeshClientType::MainClient);
		config_client_ = std::make_shared<ClientConnect>(service, MeshClientType::ConfigClient);
		main_client_->connect();
		config_client_->connect();

		IOObjectRelease(service); // Release the service object
	}

	std::expected<std::tuple<ConfigClient::NodeId, uint64_t, uint64_t>, std::string>
	AllocateSharedMemory(MainClient::BufferId buffer_id, uint64_t buffer_size, uint8_t leader_data_byte)
	{
		if (buffers_.find(buffer_id) != buffers_.end()) {
			return std::unexpected("Buffer is already allocated");
		}
		buffers_[buffer_id] = std::make_unique<uint8_t[]>(buffer_size);
		auto & buffer       = buffers_[buffer_id];

		uint64_t chunk_size               = buffer_size > kMaxBlockSize ? kMaxBlockSize : buffer_size;
		uint64_t breakdown[kMaxBreakdown] = {0};
		breakdown[0]                      = chunk_size;

		auto           node_id        = ConfigClient::NodeIdInvalid;
		constexpr auto leader_node_id = ConfigClient::NodeId(0);
		auto           res            = config_client_->Call(ConfigClient::Methods::GetLocalNodeId, sizeof(node_id), &node_id);
		if (kIOReturnSuccess != res) {
			return std::unexpected("Failed to get local node id");
		}

		if (node_id.id == leader_node_id.id) {
			memset(buffer.get(), leader_data_byte, buffer_size);
		} else {
			memset(buffer.get(), 0, buffer_size);
		}

		MainClient::SharedMemoryConfig shared_memory_config = {
		    .bufferId    = buffer_id,
		    .address     = reinterpret_cast<mach_vm_address_t>(buffer.get()),
		    .size        = buffer_size,
		    .chunkSize   = chunk_size,
		    .strideSkip  = 0,
		    .strideWidth = 0,
		};

		res = main_client_->Call(MainClient::Methods::AllocateSharedMemory, &shared_memory_config, sizeof(shared_memory_config));
		if (res == kIOReturnBadArgument) {
			/* The buffer may already be allocated, try to deallocate and then re-allocate it */
			MainClient::SharedMemoryRef shared_memory_ref = {
			    .bufferId = buffer_id,
			    .size     = buffer_size,
			};
			res = main_client_->Call(MainClient::Methods::DeallocateSharedMemory, &shared_memory_ref, sizeof(shared_memory_ref));
			if (kIOReturnSuccess != res) {
				return std::unexpected("Failed to deallocate shared memory");
			}

			res =
			    main_client_->Call(MainClient::Methods::AllocateSharedMemory, &shared_memory_config, sizeof(shared_memory_config));
		}
		if (kIOReturnSuccess != res) {
			return std::unexpected("Failed to allocate shared memory");
		}

		auto num_chunks = buffer_size / chunk_size;
		for (auto chunk = 0; chunk < num_chunks; ++chunk) {
			uint64_t offset = chunk * chunk_size;
			/* TODO: should check if is leader node and set directions accordingly */
			auto direction   = MainClient::MeshDirection::Out;
			auto source_node = leader_node_id;
			if (node_id.id == chunk) {
				direction   = MainClient::MeshDirection::In;
				source_node = node_id;
			}

			auto assignment = MainClient::AssignChunks{
			    .bufferId        = buffer_id,
			    .offset          = offset,
			    .size            = chunk_size,
			    .direction       = direction,
			    .meshChannelMask = 1,
			    .accessMode      = MainClient::AccessMode::Block,
			    .sourceNode      = source_node,
			};
			res = main_client_->Call(MainClient::Methods::AssignSharedMemoryChunk, &assignment, sizeof(assignment));
			if (kIOReturnSuccess != res) {
				return std::unexpected("Failed to assign shared memory");
			}
		}

		return std::make_tuple(node_id, num_chunks, chunk_size);
	}

	std::expected<bool, std::error_code>
	IsLeaderNode()
	{
		constexpr int host_name_max = 128;
		char          hostname[host_name_max];

		if (gethostname(hostname, host_name_max) == 0) {
			std::string hostnameStr(hostname);
			return hostnameStr.find('0') != std::string::npos;
		} else {
			// Create a std::error_code from errno.
			return std::unexpected(std::error_code(errno, std::generic_category()));
		}
	}
};

TEST_F(GuestVirtCIOMeshMockTest, Config_NotificationRegister_FailArgument)
{
	EXPECT_EQ(kIOReturnBadArgument, config_client_->Call(ConfigClient::Methods::NotificationRegister));
}

TEST_F(GuestVirtCIOMeshMockTest, Config_NotificationRegister_DummyPort)
{
	auto port = IONotificationPortCreate(kIOMainPortDefault);
	EXPECT_NE(nullptr, port);
	dispatch_queue_t queue =
	    dispatch_queue_create("com.apple.VirtMesh.tests.Config_NotificationRegister_DummyPort", DISPATCH_QUEUE_SERIAL);
	EXPECT_NE(nullptr, queue);
	IONotificationPortSetDispatchQueue(port, queue);
	io_async_ref64_t asyncRef = {};
	// asyncRef[kIOAsyncCalloutFuncIndex]   = reinterpret_cast<uintptr_t>(&notificationReceived);
	// asyncRef[kIOAsyncCalloutRefconIndex] = reinterpret_cast<uintptr_t>((__bridge void *)self);
	auto res = config_client_->Call(
	    ConfigClient::Methods::NotificationRegister,
	    IONotificationPortGetMachPort(port),
	    asyncRef,
	    kIOAsyncCalloutCount
	);
	EXPECT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_NotificationUnregister_FailArgument)
{
	EXPECT_EQ(kIOReturnBadArgument, config_client_->Call(ConfigClient::Methods::NotificationUnregister));
}

TEST_F(GuestVirtCIOMeshMockTest, Config_NotificationRegister_RegUnreg)
{
	auto port = IONotificationPortCreate(kIOMainPortDefault);
	EXPECT_NE(nullptr, port);
	io_async_ref64_t asyncRef = {};
	auto             res      = config_client_->Call(
        ConfigClient::Methods::NotificationRegister,
        IONotificationPortGetMachPort(port),
        asyncRef,
        kIOAsyncCalloutCount
    );
	EXPECT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
	res = config_client_->Call(ConfigClient::Methods::NotificationUnregister);
	EXPECT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_SetNodeId)
{
	ConfigClient::NodeId idIn{0};

	auto is_leader = IsLeaderNode();
	ASSERT_EQ(true, is_leader.has_value());
	if (!is_leader.value()) {
		idIn.id = 1;
	}

	std::cout << "Setting node id: " << idIn.id << std::endl;

	auto res = config_client_->Call(ConfigClient::Methods::SetExtendedNodeId, &idIn, sizeof(idIn));
	ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_SetChassisId_DefaultInvalid)
{
	config_client_->ExpectBadArgument(ConfigClient::Methods::SetChassisId);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_SetChassisId_Success)
{
	auto chassisId = ConfigClient::ChassisId();
	auto res       = config_client_->Call(ConfigClient::Methods::SetChassisId, &chassisId, sizeof(chassisId));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_GetCryptoKey_GetBeforeSet)
{
	constexpr size_t input_size           = 32;
	uint8_t          key_data[input_size] = {0};
	auto             input                = ConfigClient::CryptoInfo(key_data, input_size);

	auto   output      = ConfigClient::CryptoInfo(nullptr, 0);
	size_t output_size = sizeof(output);

	auto res = config_client_->Call(ConfigClient::Methods::GetCryptoKey, &input, sizeof(input), &output, &output_size);
	ASSERT_EQ(res, kIOReturnExclusiveAccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_SetCryptoKey_GetAfterSet)
{
	constexpr size_t key_size = 32;
	uint8_t          input_key[key_size];
	uint8_t          output_key[key_size];

	std::fill_n(input_key, sizeof(input_key), 0xff);
	std::fill_n(output_key, sizeof(output_key), 0x0);

	auto   input       = ConfigClient::CryptoInfo(input_key, key_size);
	auto   output      = ConfigClient::CryptoInfo(nullptr, 0);
	size_t output_size = sizeof(output);

	auto res = config_client_->Call(ConfigClient::Methods::SetCryptoKey, &input, sizeof(input));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	std::cout << "Successfully set the crypto key" << std::endl;

	auto input_output = ConfigClient::CryptoInfo(output_key, key_size);
	res = config_client_->Call(ConfigClient::Methods::GetCryptoKey, &input_output, sizeof(input_output), &output, &output_size);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	std::print(
	    "Successfully got the crypto key: flags [{}] keyDataLen [{}] keyData [0x{:x}]\n",
	    static_cast<int>(output.flags),
	    output.keyDataLen,
	    reinterpret_cast<uint64_t>(output.keyData)
	);

	ASSERT_EQ(output.flags, input.flags);
	ASSERT_EQ(output.keyDataLen, input.keyDataLen);

	ASSERT_EQ(output.keyData, nullptr) << "The output key should be in the input struct, not the output struct";
	ASSERT_NE(input_output.keyData, nullptr) << "The input_output key should be in the input_output struct";

	if (input_output.keyData != nullptr) {
		for (size_t i = 0; i < input_output.keyDataLen; i++) {
			ASSERT_EQ(input_key[i], static_cast<uint8_t *>(input_output.keyData)[i]);
		}
	}
}

/**
 *	@todo Implement a few subsets of integration tests that may fail the machine and thus run each subset with a reboot.
 */

TEST_F(GuestVirtCIOMeshMockTest, Config_GetHardwareState)
{
	auto output_hw_state = ConfigClient::HardwareState();

	auto res = config_client_->Call(ConfigClient::Methods::GetHardwareState, sizeof(output_hw_state), &output_hw_state);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	ASSERT_EQ(output_hw_state.meshLinksPerChannel, 1);
	ASSERT_EQ(output_hw_state.meshChannelCount, 1);
	ASSERT_EQ(output_hw_state.meshLinkCount, 1);
	ASSERT_EQ(output_hw_state.maxMeshChannelCount, kMaxMeshChannelCount);
	ASSERT_EQ(output_hw_state.maxMeshLinkCount, kMaxMeshLinkCount);
}

/* NOTE: Lock and IsLocked tests should be performed at the end */

TEST_F(GuestVirtCIOMeshMockTest, Config_IsLocked_DefaultUnlocked)
{
	GTEST_SKIP() << "Lock could fail the machine, skipping and would need a reboot-based test environment";
	auto res = config_client_->Call(ConfigClient::Methods::IsLocked);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_Lock_CheckAfterLock)
{
	GTEST_SKIP() << "Lock could fail the machine, skipping and would need a reboot-based test environment";
	auto res = config_client_->Call(ConfigClient::Methods::Lock);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	/* Double lock should return busy */
	res = config_client_->Call(ConfigClient::Methods::Lock);
	ASSERT_EQ(res, kIOReturnBusy) << mach_error_string(res);

	res = config_client_->Call(ConfigClient::Methods::Lock);
	ASSERT_EQ(res, kIOReturnNotReady) << mach_error_string(res);

	/* Deactivate should unlock */
	res = config_client_->Call(ConfigClient::Methods::Deactivate);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
	res = config_client_->Call(ConfigClient::Methods::IsLocked);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	/* Activate to unblock follow up tests*/
	res = config_client_->Call(ConfigClient::Methods::Activate);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_DisconnectCIOChannel)
{
	ConfigClient::MeshChannelIdx channel = 0;
	auto                         res = config_client_->Call(ConfigClient::Methods::DisconnectCIOChannel, &channel, sizeof(channel));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_CanActivate_2Node_Success)
{
	ConfigClient::MeshNodeCount count = 2;
	auto                        res   = config_client_->Call(ConfigClient::Methods::CanActivate, &count, sizeof(count));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_CanActivate_4Node_Fail)
{
	ConfigClient::MeshNodeCount count = 4;
	auto                        res   = config_client_->Call(ConfigClient::Methods::CanActivate, &count, sizeof(count));
	ASSERT_EQ(res, kIOReturnUnsupported) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_CanActivate_8Node_Fail)
{
	ConfigClient::MeshNodeCount count = 8;
	auto                        res   = config_client_->Call(ConfigClient::Methods::CanActivate, &count, sizeof(count));
	ASSERT_EQ(res, kIOReturnUnsupported) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_GetBuffersUsedByKey)
{
	uint64_t total_buffers = 0xff;
	auto     output_size   = sizeof(total_buffers);

	auto res = config_client_->Call(ConfigClient::Methods::GetBuffersUsedByKey, output_size, &total_buffers);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	ASSERT_EQ(total_buffers, 0);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_GetCIOConnectionState)
{
	ConfigClient::CIOConnections conn;
	auto                         res = config_client_->Call(ConfigClient::Methods::GetCIOConnectionState, sizeof(conn), &conn);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	ASSERT_EQ(conn.cioCount, 2);

	auto curr_node_id = 0;
	if (conn.cio[1].cableConnected == false) {
		curr_node_id = 1;
	}

	for (auto i = 0; i < conn.cioCount; i++) {
		std::print(
		    "CIOConnections cio[{}] cableConnected [{}] expectedPeerHardwareNodeId [{}] actualPeerHardwareNodeId [{}]\n",
		    i,
		    conn.cio[i].cableConnected,
		    conn.cio[i].expectedPeerHardwareNodeId,
		    conn.cio[i].actualPeerHardwareNodeId
		);
	}

	for (auto i = 0; i < conn.cioCount; i++) {
		if (i == curr_node_id) {
			ASSERT_EQ(conn.cio[i].cableConnected, false);
			ASSERT_EQ(conn.cio[i].expectedPeerHardwareNodeId, ConfigClient::kNonDCHardwarePlatform);
			ASSERT_EQ(conn.cio[i].actualPeerHardwareNodeId, ConfigClient::kNonDCHardwarePlatform);
		} else {
			ASSERT_EQ(conn.cio[i].cableConnected, true);
			ASSERT_EQ(conn.cio[i].expectedPeerHardwareNodeId, i);
			ASSERT_EQ(conn.cio[i].actualPeerHardwareNodeId, i);
		}
	}
}

TEST_F(GuestVirtCIOMeshMockTest, Config_EstablishTxConnection_DummyImpl)
{
	ConfigClient::NodeConnectionInfo info;
	auto                             res = config_client_->Call(ConfigClient::Methods::EstablishTxConnection, &info, sizeof(info));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_SendControlMessage)
{
	auto message   = ConfigClient::MeshMessage();
	message.length = 16;
	memset(message.rawData, 0xff, message.length);

	/* TODO: Check the notification call back from kext to see if message is actually coming. */
	auto res = config_client_->Call(ConfigClient::Methods::SendControlMessage, &message, sizeof(message));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	res = config_client_->Call(ConfigClient::Methods::SendControlMessage, &message, sizeof(message));
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_Deactivate)
{
	GTEST_SKIP() << "deactivate() will cause setting and getting properties failed after this point, skipping until we implement "
	                "more robuset test cases";
	auto res = config_client_->Call(ConfigClient::Methods::Deactivate);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	res = config_client_->Call(ConfigClient::Methods::Activate);
	ASSERT_EQ(res, kIOReturnError) << mach_error_string(res);
}

/* Activate will lock the mesh, and caused a few config apis to be unavailable, so running activate at the end of config tests. */
TEST_F(GuestVirtCIOMeshMockTest, Config_ActivateAndLock)
{
	auto res = config_client_->Call(ConfigClient::Methods::Activate);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	res = config_client_->Call(ConfigClient::Methods::Lock);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Config_GetConnectedNodes)
{
	ConfigClient::ConnectedNodes nodes;
	auto                         res = config_client_->Call(ConfigClient::Methods::GetConnectedNodes, sizeof(nodes), &nodes);
	ASSERT_EQ(res, kIOReturnSuccess) << mach_error_string(res);

	ASSERT_EQ(nodes.nodeCount, 2);
}

TEST_F(GuestVirtCIOMeshMockTest, Main_NotificationRegister_FailArgument)
{
	ASSERT_EQ(kIOReturnBadArgument, main_client_->Call(MainClient::Methods::NotificationRegister));
}

TEST_F(GuestVirtCIOMeshMockTest, Main_NotificationRegister_DummyPort)
{
	auto port = IONotificationPortCreate(kIOMainPortDefault);
	ASSERT_NE(nullptr, port);

	dispatch_queue_t queue =
	    dispatch_queue_create("com.apple.VirtMesh.tests.Main_NotificationRegister_DummyPort", DISPATCH_QUEUE_SERIAL);
	ASSERT_NE(nullptr, queue);
	IONotificationPortSetDispatchQueue(port, queue);

	io_async_ref64_t asyncRef = {};
	// asyncRef[kIOAsyncCalloutFuncIndex]   = reinterpret_cast<uintptr_t>(&notificationReceived);
	// asyncRef[kIOAsyncCalloutRefconIndex] = reinterpret_cast<uintptr_t>((__bridge void *)self);

	auto res =
	    main_client_
	        ->Call(MainClient::Methods::NotificationRegister, IONotificationPortGetMachPort(port), asyncRef, kIOAsyncCalloutCount);
	ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
}

TEST_F(GuestVirtCIOMeshMockTest, Main_SynchronizeGeneration)
{
	auto res = main_client_->Call(MainClient::Methods::SynchronizeGeneration);
	ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);

	res = main_client_->Call(MainClient::Methods::SynchronizeGeneration);
	ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
}

/* clang-format off */
// TEST_F(GuestVirtCIOMeshMockTest, Main_AllocateSharedMemory)    { main_client_->ExpectUnimplemented(MainClient::Methods::AllocateSharedMemory    ); }
// TEST_F(GuestVirtCIOMeshMockTest, Main_DeallocateSharedMemory)  { main_client_->ExpectUnimplemented(MainClient::Methods::DeallocateSharedMemory  ); }
// TEST_F(GuestVirtCIOMeshMockTest, Main_AssignSharedMemoryChunk) { main_client_->ExpectUnimplemented(MainClient::Methods::AssignSharedMemoryChunk ); }
// TEST_F(GuestVirtCIOMeshMockTest, Main_SetMaxWaitTime)          { main_client_->ExpectUnimplemented(MainClient::Methods::SetMaxWaitTime          ); }
TEST_F(GuestVirtCIOMeshMockTest, Main_PrintBufferState)        { main_client_->ExpectUnimplemented(MainClient::Methods::PrintBufferState        ); }
TEST_F(GuestVirtCIOMeshMockTest, Main_SetupForwardChainBuffers){ main_client_->ExpectUnimplemented(MainClient::Methods::SetupForwardChainBuffers); }
TEST_F(GuestVirtCIOMeshMockTest, Main_SetMaxWaitPerNodeBatch)  { main_client_->ExpectUnimplemented(MainClient::Methods::SetMaxWaitPerNodeBatch  ); }
/* clang-format on */

/* MainClient Trap methods */

/* clang-format off */
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_WaitSharedMemoryChunk)		{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::WaitSharedMemoryChunk);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_SendAssignedData)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::SendAssignedData);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_PrepareChunk)				{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::PrepareChunk);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_PrepareAllChunks)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::PrepareAllChunks);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_SendAndPrepareChunk)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::SendAndPrepareChunk);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_SendAllAssignedChunks)		{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::SendAllAssignedChunks);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_ReceiveAll)					{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::ReceiveAll);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_ReceiveNext)					{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::ReceiveNext);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_ReceiveBatch)				{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::ReceiveBatch);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_ReceiveBatchForNode)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::ReceiveBatchForNode);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_InterruptWaitingThreads)		{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::InterruptWaitingThreads);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_ClearInterruptState)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::ClearInterruptState);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_InterruptReceiveBatch)		{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::InterruptReceiveBatch);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_StartForwardChain)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::StartForwardChain);}
// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_StopForwardChain)			{ main_client_->ExpectUnimplementedTrap(MainClient::Traps::StopForwardChain);}
/* clang-format on */

// TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_SendAndReceive)
// {
// 	MainClient::BufferId buffer_id   = 1;
// 	int64_t              buffer_size = 512 * 1024;

// 	uint8_t leader_data_byte = 0xff;
// 	auto    result           = AllocateSharedMemory(buffer_id, buffer_size, leader_data_byte);
// 	ASSERT_TRUE(result.has_value()) << "Unexpected error: " << result.error();
// 	auto [node_id, num_chunks, chunk_size] = *result;

// TODO: need to actually send and receive

// 	auto & buffer_data = buffers_[buffer_id];
// 	if (node_id.id != leader_node_id_.id) {
// 		for (auto byte = 0; byte < buffer_size; ++byte) {
// 			uint8_t buffer_data_byte = buffer_data[byte];
// 			ASSERT_EQ(buffer_data_byte, leader_data_byte) << "Follower failed to receive the leader data, [" << buffer_data_byte
// 			                                              << "] != [" << leader_data_byte << "] at offset [" << byte << "]";
// 		}
// 	}
// 	/* TODO: Deallocate shared memory */
// }

/* TODO: the send and receive unit tests are problematic */

TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_SendAndReceive1MiB)
{
	/* 1MiB is the largest buffer that can be sent directly using `SendAssignedData` */
	uint64_t buffer_id        = 2;
	uint64_t buffer_size      = 1 * 1024 * 1024;
	uint8_t  leader_data_byte = 0xff;
	auto     result           = AllocateSharedMemory(buffer_id, buffer_size, leader_data_byte);
	ASSERT_TRUE(result.has_value()) << "Unexpected error: " << result.error();
	auto [node_id, num_chunks, chunk_size] = *result;

	/* Simplified from the folowing code:
	 * llmsim - llm_worker()
	 * -> AppleCIOMeshAPI - MeshSendToAllPeers/MeshReceiveFromLeaderEx
	 * -> AppleCIOMeshServiceRef
	 */
	for (auto chunk = 0; chunk < num_chunks; ++chunk) {
		auto offset = chunk * chunk_size;

		auto res = main_client_->Trap(MainClient::Traps::PrepareChunk, buffer_id, offset);
		ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);

		char tag[2][Config::kTagSize];
		if (node_id.id == leader_node_id_.id) {
			res = main_client_->Trap(MainClient::Traps::SendAssignedData, buffer_id, offset, (uintptr_t)(&tag[0][0]));
			ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
		} else {
			res = main_client_->Trap(MainClient::Traps::WaitSharedMemoryChunk, buffer_id, offset, (uintptr_t)(&tag[0][0]));
			ASSERT_EQ(kIOReturnSuccess, res) << mach_error_string(res);
		}
	}

	auto & buffer_data = buffers_[buffer_id];
	if (node_id.id != leader_node_id_.id) {
		for (auto byte = 0; byte < buffer_size; ++byte) {
			uint8_t buffer_data_byte = buffer_data[byte];
			ASSERT_EQ(buffer_data_byte, leader_data_byte) << "Follower failed to receive the leader data, [" << buffer_data_byte
			                                              << "] != [" << leader_data_byte << "] at offset [" << byte << "]";
		}
	}
}

TEST_F(GuestVirtCIOMeshMockTest, Main_Trap_SendAndReceiveAll4MiB)
{
	uint64_t buffer_size      = 4 * 1024 * 1024;
	uint8_t  leader_data_byte = 0xff;

	uint64_t buffer_id = 3;
	auto     result    = AllocateSharedMemory(buffer_id, buffer_size, leader_data_byte);
	ASSERT_TRUE(result.has_value()) << "Unexpected error: " << result.error();

	auto               node_id     = std::get<0>(*result);
	constexpr uint64_t count_batch = 2 - 1; /* Total two nodes, exclude myself */

	MainClient::CryptoTag tags[2];

	auto trap_res = main_client_->Trap(MainClient::Traps::SendAllAssignedChunks, buffer_id, (uintptr_t)&(tags[0]));
	ASSERT_EQ(kIOReturnSuccess, trap_res) << mach_error_string(trap_res);

	uint64_t              count_received_out = 0;
	uint64_t              offset_received_out[2];
	MainClient::CryptoTag tag_received_out[2];
	trap_res = main_client_->Trap(
	    MainClient::Traps::ReceiveBatchForNode,
	    buffer_id,
	    node_id.id,
	    count_batch,
	    (uintptr_t)&count_received_out,
	    (uintptr_t)&(offset_received_out[0]),
	    (uintptr_t)&(tag_received_out[0])
	);
	ASSERT_EQ(kIOReturnSuccess, trap_res) << mach_error_string(trap_res);
}
