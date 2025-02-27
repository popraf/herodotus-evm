// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {TimestampToBlockNumberMapper} from "../src/timestamps-mapper/TimestampToBlockNumberMapper.sol";
import {Types} from "../src/lib/Types.sol";

uint256 constant DEFAULT_TREE_ID = 0;

contract MockedHeadersProcessor {
    bytes32 constant ROOT_OF_MMR_CONTAINING_BLOCK_7583802_AT_INDEX_1 = 0x7925fc646e7ff14336b092e12adf5b66e8da65a06b14c486c231fcb92ca6c74c;
    uint256 constant SIZE_OF_MMR_CONTAINING_BLOCK_7583802_AT_INDEX_1 = 7;

    function getMMRRoot(uint256 mmrId, uint256 mmrSize) external pure returns (bytes32) {
        require(mmrId == DEFAULT_TREE_ID, "ERR_INVALID_MMR_ID");
        require(mmrSize == SIZE_OF_MMR_CONTAINING_BLOCK_7583802_AT_INDEX_1, "ERR_INVALID_MMR_SIZE");
        return ROOT_OF_MMR_CONTAINING_BLOCK_7583802_AT_INDEX_1;
    }
}

contract TimestampToBlockNumberMapper_Test is Test {
    using stdStorage for StdStorage;
    using Strings for uint256;

    TimestampToBlockNumberMapper mapper;

    constructor() {
        MockedHeadersProcessor mockedHeadersProcessor = new MockedHeadersProcessor();
        mapper = new TimestampToBlockNumberMapper(address(mockedHeadersProcessor));
    }

    function test_createMapper() public {
        uint256 startBlockNumber = 7583801;
        uint256 mapperId = _createMapper(7583801);

        uint256 newMappersCount = mapper.mappersCount();
        assertEq(newMappersCount, 1);

        bool isInitialized = mapper.isMapperInitialized(mapperId);
        assertTrue(isInitialized);

        uint256 setStartBlockNumber = mapper.getMapperStartsFromBlock(mapperId);
        assertEq(setStartBlockNumber, startBlockNumber);

        uint256 latestSize = mapper.getMapperLatestSize(mapperId);
        assertEq(latestSize, 0);
    }

    function test_reindexBatch() public {
        uint256 mapperId = _createMapper(7583800);

        (bytes32[] memory headersMMRPeaks, bytes32[] memory block7583800MMRInclusionProof) = _peaksAndInclusionProofForBlock(4);
        (, bytes32[] memory block7583801MMRInclusionProof) = _peaksAndInclusionProofForBlock(2);
        (, bytes32[] memory block7583802MMRInclusionProof) = _peaksAndInclusionProofForBlock(1);

        Types.BlockHeaderProof memory header_x_proof = Types.BlockHeaderProof({
            treeId: DEFAULT_TREE_ID,
            mmrTreeSize: 7,
            blockNumber: 7583800,
            blockProofLeafIndex: 4,
            mmrPeaks: headersMMRPeaks,
            mmrElementInclusionProof: block7583800MMRInclusionProof,
            provenBlockHeader: _getRlpBlockHeader(7583800)
        });
        Types.BlockHeaderProof memory header_x_plus_one_proof = Types.BlockHeaderProof({
            treeId: DEFAULT_TREE_ID,
            mmrTreeSize: 7,
            blockNumber: 7583801,
            blockProofLeafIndex: 2,
            mmrPeaks: headersMMRPeaks,
            mmrElementInclusionProof: block7583801MMRInclusionProof,
            provenBlockHeader: _getRlpBlockHeader(7583801)
        });
        Types.BlockHeaderProof memory header_x_plus_two_proof = Types.BlockHeaderProof({
            treeId: DEFAULT_TREE_ID,
            mmrTreeSize: 7,
            blockNumber: 7583802,
            blockProofLeafIndex: 1,
            mmrPeaks: headersMMRPeaks,
            mmrElementInclusionProof: block7583802MMRInclusionProof,
            provenBlockHeader: _getRlpBlockHeader(7583802)
        });

        Types.BlockHeaderProof[] memory headersBatch = new Types.BlockHeaderProof[](3);
        headersBatch[0] = header_x_proof;
        headersBatch[1] = header_x_plus_one_proof;
        headersBatch[2] = header_x_plus_two_proof;

        bytes32[] memory emptyPeaks = new bytes32[](0);
        mapper.reindexBatch(mapperId, emptyPeaks, headersBatch);

        uint256 newMMRSize = mapper.getMapperLatestSize(mapperId);
        assertEq(newMMRSize, 4);
    }

    function test_binsearchBlockNumberByTimestamp() public {
        test_reindexBatch();

        uint256 queriedTimestamp = 1663065482;
        uint256 expectedCorrespondingBlockNumber = 7583801;

        uint256[] memory timestamps = new uint256[](3);
        timestamps[0] = 1663065468;
        timestamps[1] = 1663065480;
        timestamps[2] = 1663065492;

        (bytes32[] memory peaks, bytes32[] memory firstElementInclusionProof) = _peaksAndInclusionProofForTimestamp(2);
        (bytes32[] memory newPeaks, bytes32[] memory secondElementInclusionProof) = _peaksAndInclusionProofForTimestamp(4);
        assertEq(keccak256(abi.encode(peaks)), keccak256(abi.encode(newPeaks)));

        TimestampToBlockNumberMapper.BinsearchPathElement memory firstSearchPathElement = TimestampToBlockNumberMapper.BinsearchPathElement(
            2,
            bytes32(timestamps[1]),
            firstElementInclusionProof
        );
        TimestampToBlockNumberMapper.BinsearchPathElement memory secondSearchPathElement = TimestampToBlockNumberMapper.BinsearchPathElement(
            4,
            bytes32(timestamps[2]),
            secondElementInclusionProof
        );

        TimestampToBlockNumberMapper.BinsearchPathElement[] memory searchPath = new TimestampToBlockNumberMapper.BinsearchPathElement[](2);
        searchPath[0] = firstSearchPathElement;
        searchPath[1] = secondSearchPathElement;

        uint256 result = mapper.binsearchBlockNumberByTimestamp(DEFAULT_TREE_ID, 4, peaks, queriedTimestamp, searchPath);
        assertEq(result, expectedCorrespondingBlockNumber);
    }

    function test_binsearchBlockNumberByTimestampBiggerTree() public {
        uint256 mapperId = _createMapper(7583800);

        uint256[] memory timestamps = new uint256[](5);
        timestamps[0] = 1663065468;
        timestamps[1] = 1663065480;
        timestamps[2] = 1663065492;
        timestamps[3] = 1663065504;
        timestamps[4] = 1663065516;

        (bytes32 root /*bytes32[] memory peaks, bytes32[] memory inclusionProof*/, , ) = _rootAndProofForMapperFedWithPredefinedTimestamps(1, timestamps);
        uint256 mmrSize = 8;

        stdstore.target(address(mapper)).sig(mapper.getMapperLatestSize.selector).with_key(mapperId).checked_write(bytes32(mmrSize));

        stdstore.target(address(mapper)).sig(mapper.getMapperRootAtSize.selector).with_key(mapperId).with_key(mmrSize).checked_write(root);

        // Ensure storage is set correctly
        assertEq(mapper.getMapperLatestSize(mapperId), mmrSize);
        assertEq(mapper.getMapperRootAtSize(mapperId, mmrSize), root);
    }

    function _createMapper(uint256 startBlockNumber) internal returns (uint256) {
        return mapper.createMapper(startBlockNumber);
    }

    function _rootAndProofForMapperFedWithPredefinedTimestamps(
        uint256 elementId,
        uint256[] memory timestamps
    ) internal returns (bytes32 root, bytes32[] memory peaks, bytes32[] memory inclusionProof) {
        string[] memory inputs = new string[](3 + timestamps.length);
        inputs[0] = "node";
        inputs[1] = "./helpers/mmrs/get_peaks_and_inclusion_proof.js";
        inputs[2] = elementId.toString(); // Generate proof for leaf with id
        for (uint256 i = 0; i < timestamps.length; i++) {
            inputs[3 + i] = timestamps[i].toString();
        }
        bytes memory abiEncoded = vm.ffi(inputs);
        (root, peaks, inclusionProof) = abi.decode(abiEncoded, (bytes32, bytes32[], bytes32[]));
        return (root, peaks, inclusionProof);
    }

    function _peaksAndInclusionProofForTimestamp(uint256 elementId) internal returns (bytes32[] memory peaks, bytes32[] memory inclusionProof) {
        require(5 > elementId, "ERR_TEST_MOCKED_HEADERS_PROCESSOR_HAS_ONLY_3_TIMESTAMPS");
        require(mapper.getMapperLatestRoot(0) == 0xb466a01610d46c5694c66b0b1afa741e0d1593c8dc975ee5384d032b2f68c211, "ERR_TEST_MOCKED_HEADERS_PROCESSOR_HAS_ONLY_3_TIMESTAMPS");

        uint256[] memory timestamps = new uint256[](3);

        timestamps[0] = 1663065468;
        timestamps[1] = 1663065480;
        timestamps[2] = 1663065492;

        string[] memory inputs = new string[](3 + timestamps.length);
        inputs[0] = "node";
        inputs[1] = "./helpers/mmrs/get_peaks_and_inclusion_proof.js";
        inputs[2] = elementId.toString(); // Generate proof for leaf with id
        for (uint256 i = 0; i < timestamps.length; i++) {
            inputs[3 + i] = timestamps[i].toString();
        }
        bytes memory abiEncoded = vm.ffi(inputs);
        (, peaks, inclusionProof) = abi.decode(abiEncoded, (bytes32, bytes32[], bytes32[]));
    }

    function _peaksAndInclusionProofForBlock(uint256 leafId) internal returns (bytes32[] memory peaks, bytes32[] memory inclusionProof) {
        require(6 > leafId, "ERR_TEST_MOCKED_HEADERS_PROCESSOR_HAS_ONLY_4_BLOCKS");

        bytes[] memory headersBatch = new bytes[](4);
        headersBatch[0] = _getRlpBlockHeader(7583802);
        headersBatch[1] = _getRlpBlockHeader(7583801);
        headersBatch[2] = _getRlpBlockHeader(7583800);
        headersBatch[3] = _getRlpBlockHeader(7583801);

        string[] memory inputs = new string[](3 + headersBatch.length);
        inputs[0] = "node";
        inputs[1] = "./helpers/mmrs/get_peaks_and_inclusion_proof.js";
        inputs[2] = leafId.toString(); // Generate proof for leaf with id
        for (uint256 i = 0; i < headersBatch.length; i++) {
            bytes32 headerHash = keccak256(headersBatch[i]);
            inputs[3 + i] = uint256(headerHash).toHexString();
        }

        bytes memory abiEncoded = vm.ffi(inputs);
        (, peaks, inclusionProof) = abi.decode(abiEncoded, (bytes32, bytes32[], bytes32[]));
    }

    function _getRlpBlockHeader(uint256 blockNumber) internal returns (bytes memory) {
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "./helpers/fetch_header_rlp.js";
        inputs[2] = blockNumber.toString();
        bytes memory headerRlp = vm.ffi(inputs);
        return headerRlp;
    }
}
