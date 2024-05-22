// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224; // 使用 UQ112x112 库来处理 uint224 类型的特殊运算

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3; // 定义最小流动性常量
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)"))); // 定义 transfer 函数的选择器

    address public factory;
    address public token0;
    address public token1;

    // token0 的储备量
    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    // token1 的储备量
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    // 累计价格, 用于计算加权平均价格
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    // 最后一次流动性事件后的 k 值
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint256 private unlocked = 1; // 标记是否解锁

    // 定义一个锁定功能的 modifier，防止重入攻击
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED"); // 检查是否已解锁
        unlocked = 0; // 锁定
        _;
        unlocked = 1; // 解锁
    }

    // 获取储备量和最后一次区块时间戳
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // 安全 Transfer, 防止合约调用失败
    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapV2: TRANSFER_FAILED");
    }

    // event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    // event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    // event Swap(
    //     address indexed sender,
    //     uint256 amount0In,
    //     uint256 amount1In,
    //     uint256 amount0Out,
    //     uint256 amount1Out,
    //     address indexed to
    // );
    // event Sync(uint112 reserve0, uint112 reserve1);

    // constructor() public {
    //     factory = msg.sender;
    // }

    // 构造函数，设置工厂地址
    constructor() {
        factory = msg.sender;
    }

    // 由工厂在部署时调用一次，用于初始化代币地址
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN"); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
    //     require(balance0 <= uint112(-1) && balance1 <= uint112(-1), "UniswapV2: OVERFLOW");
    //     uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
    //     uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
    //     if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
    //         // * never overflows, and + overflow is desired
    //         price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
    //         price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
    //     }
    //     reserve0 = uint112(balance0);
    //     reserve1 = uint112(balance1);
    //     blockTimestampLast = blockTimestamp;
    //     emit Sync(reserve0, reserve1);
    // }

    // 更新储备量，并在每个区块第一次调用时更新价格累加器
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "UniswapV2: OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // 溢出是期望的
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            unchecked {
                // token0 相对于 token1 的累计价格
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                // token1 相对于 token0 的累计价格
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    // 如果费用开启，铸造相当于增长的1/6的流动性
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo(); // 获取收取费用的地址
        feeOn = feeTo != address(0); // 检查是否开启费用
        uint256 _kLast = kLast; // 节省gas
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1)); // 计算当前储备量的平方根
                uint256 rootKLast = Math.sqrt(_kLast); // 计算上一次储备量的平方根
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint256 denominator = rootK.mul(5).add(rootKLast);
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity); // 铸造流动性
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 此低级函数应从执行重要安全检查的合约中调用
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // 获取储备量，节省gas
        uint256 balance0 = IERC20(token0).balanceOf(address(this)); // 获取当前合约中的代币0余额
        uint256 balance1 = IERC20(token1).balanceOf(address(this)); // 获取当前合约中的代币1余额
        uint256 amount0 = balance0.sub(_reserve0); // 计算增加的代币0数量
        uint256 amount1 = balance1.sub(_reserve1); // 计算增加的代币1数量

        bool feeOn = _mintFee(_reserve0, _reserve1); // 检查并铸造费用
        uint256 _totalSupply = totalSupply; // 节省gas，必须在这里定义，因为 totalSupply 可以在 _mintFee 中更新
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY); // 计算初始流动性
            _mint(address(0), MINIMUM_LIQUIDITY); // 永久锁定最小流动性代币
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1); // 计算流动性
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED"); // 检查流动性是否足够
        _mint(to, liquidity); // 铸造流动性代币

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // 更新 kLast
        emit Mint(msg.sender, amount0, amount1); // 触发铸造事件
    }

    // 此低级函数应从执行重要安全检查的合约中调用
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // 获取储备量，节省gas
        address _token0 = token0; // 节省gas
        address _token1 = token1; // 节省gas
        uint256 balance0 = IERC20(_token0).balanceOf(address(this)); // 获取当前合约中的代币0余额
        uint256 balance1 = IERC20(_token1).balanceOf(address(this)); // 获取当前合约中的代币1余额
        uint256 liquidity = balanceOf[address(this)]; // 获取当前合约中的流动性代币余额

        bool feeOn = _mintFee(_reserve0, _reserve1); // 检查并铸造费用
        uint256 _totalSupply = totalSupply; // 节省gas，必须在这里定义，因为 totalSupply 可以在 _mintFee 中更新
        amount0 = liquidity.mul(balance0) / _totalSupply; // 按照比例计算代币0的数量
        amount1 = liquidity.mul(balance1) / _totalSupply; // 按照比例计算代币1的数量
        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED"); // 检查流动性是否足够
        _burn(address(this), liquidity); // 销毁流动性代币
        _safeTransfer(_token0, to, amount0); // 安全转移代币0
        _safeTransfer(_token1, to, amount1); // 安全转移代币1
        balance0 = IERC20(_token0).balanceOf(address(this)); // 获取更新后的代币0余额
        balance1 = IERC20(_token1).balanceOf(address(this)); // 获取更新后的代币1余额

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // 更新 kLast
        emit Burn(msg.sender, amount0, amount1, to); // 触发销毁事件
    }

    // 此低级函数应从执行重要安全检查的合约中调用
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"); // 检查输出数量是否足够
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // 获取储备量，节省gas
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY"); // 检查储备量是否足够

        uint256 balance0;
        uint256 balance1;
        {
            // 为 _token{0,1} 创建作用域，避免堆栈过深错误
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO"); // 检查目标地址是否有效
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // 乐观地转移代币0
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // 乐观地转移代币1
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data); // 如果有数据，调用回调函数
            balance0 = IERC20(_token0).balanceOf(address(this)); // 获取更新后的代币0余额
            balance1 = IERC20(_token1).balanceOf(address(this)); // 获取更新后的代币1余额
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0; // 计算输入的代币0数量
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0; // 计算输入的代币1数量
        require(amount0In > 0 || amount1In > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"); // 检查输入数量是否足够
        {
            // 为 reserve{0,1}Adjusted 创建作用域，避免堆栈过深错误
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint256(_reserve0).mul(_reserve1).mul(1000 ** 2),
                "UniswapV2: K"
            ); // 确保恒定乘积
        }

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to); // 触发交换事件
    }

    // 强制余额与储备量匹配
    function skim(address to) external lock {
        address _token0 = token0; // 节省gas
        address _token1 = token1; // 节省gas
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0)); // 安全转移代币0
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1)); // 安全转移代币1
    }

    // 强制储备量与余额匹配
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1); // 更新储备量
    }
}
