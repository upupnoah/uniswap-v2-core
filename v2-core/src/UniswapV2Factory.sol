// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// 引入 IUniswapV2Factory 接口和 UniswapV2Pair 合约
import "./interfaces/IUniswapV2Factory.sol";
import "./UniswapV2Pair.sol";

// 定义 UniswapV2Factory 合约，实现了 IUniswapV2Factory 接口
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; // 收取手续费的地址
    address public feeToSetter; // 设置手续费收取地址的权限者

    // 存储每对代币对应的交易对地址
    mapping(address token0 => mapping(address token1 => address pairAddr)) public getPair;
    address[] public allPairs; // 所有交易对的数组

    // event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    // constructor(address _feeToSetter) public {
    //     feeToSetter = _feeToSetter;
    // }

    // 构造函数，初始化 feeToSetter
    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    // 获取所有交易对的数量
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    // 创建新的交易对
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "UniswapV2: IDENTICAL_ADDRESSES"); // 确保两个代币地址不同
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA); // 确保 token0 < token1
        require(token0 != address(0), "UniswapV2: ZERO_ADDRESS"); // 确保代币地址不为零
        require(getPair[token0][token1] == address(0), "UniswapV2: PAIR_EXISTS"); // 确保交易对不存在

        // 获取 UniswapV2Pair 合约的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1)); // 生成盐值，用于 create2 函数

        // 使用内联汇编创建新的 UniswapV2Pair 合约
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // 初始化新创建的交易对
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 更新 getPair 映射
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // 反向更新映射
        allPairs.push(pair); // 将新交易对添加到 allPairs 数组中
        // 触发 PairCreated 事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 设置手续费收取地址 -> 平台收取手续费的地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "UniswapV2: FORBIDDEN"); // 确保只有 feeToSetter 可以调用
        feeTo = _feeTo;
    }

    // 设置新的手续费收取地址
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "UniswapV2: FORBIDDEN"); // 确保只有 feeToSetter 可以调用
        feeToSetter = _feeToSetter;
    }
}
