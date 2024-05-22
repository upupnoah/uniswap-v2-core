// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./interfaces/IUniswapV2ERC20.sol";
import "./libraries/SafeMath.sol";

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint256;

    // 代币名称、符号和小数位的常量值
    string public constant name = "Uniswap V2";
    string public constant symbol = "UNI-V2";
    uint8 public constant decimals = 18;

    // 代币总供应量和账户余额的状态变量
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // 域分隔符（用于 EIP-712 签名）
    bytes32 public DOMAIN_SEPARATOR;
    // 用于 Permit 的类型哈希值
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint256) public nonces;

    // event Approval(address indexed owner, address indexed spender, uint256 value);
    // event Transfer(address indexed from, address indexed to, uint256 value);

    // constructor() public {
    //     uint256 chainId;
    //     assembly {
    //         chainId := chainid()
    //     }
    //     DOMAIN_SEPARATOR = keccak256(
    //         abi.encode(
    //             keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    //             keccak256(bytes(name)),
    //             keccak256(bytes("1")),
    //             chainId,
    //             address(this)
    //         )
    //     );
    // }

    // 合约构造函数，用于初始化 DOMAIN_SEPARATOR
    constructor() {
        uint256 chainId;
        // 使用内联汇编获取当前链的 chainId
        assembly {
            chainId := chainid()
        }
        // 计算 DOMAIN_SEPARATOR，用于 EIP-712 签名
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                // 使用 EIP-712 域名分隔符规范
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                // 合约名称的哈希值
                keccak256(bytes(name)),
                // 版本号的哈希值
                keccak256(bytes("1")),
                // 当前链的 chainId
                chainId,
                // 当前合约地址
                address(this)
            )
        );
    }

    // 内部函数 _mint 用于铸造代币
    function _mint(address to, uint256 value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    // 内部函数 _burn 用于销毁代币
    function _burn(address from, uint256 value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    // 内部函数 _approve 用于批准代币转移
    function _approve(address owner, address spender, uint256 value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // 内部函数 _transfer 用于转移代币
    function _transfer(address from, address to, uint256 value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    // 外部函数 approve 用于用户批准代币转移
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    // 外部函数 transfer 用于用户转移代币
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }
    // function transferFrom(address from, address to, uint256 value) external returns (bool) {
    //     if (allowance[from][msg.sender] != uint256(-1)) {
    //         allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
    //     }
    //     _transfer(from, to, value);
    //     return true;
    // }

    // 外部函数 transferFrom 用于从一个账户转移代币到另一个账户
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            unchecked {
                allowance[from][msg.sender] -= value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    // 外部函数 permit 用于基于签名的授权转移
    // 允许账户所有者通过离线签名授权第三方账户进行代币转移，无需在线进行交易批准
    function permit(
        address owner, // 代币所有者地址
        address spender, // 授权的代币使用者地址
        uint256 value, // 授权的代币数量
        uint256 deadline, // 授权的有效期截止时间
        uint8 v, // 签名的 v 值
        bytes32 r, // 签名的 r 值
        bytes32 s // 签名的 s 值
    ) external {
        // 确保授权未过期
        require(deadline >= block.timestamp, "UniswapV2: EXPIRED");
        // 计算 EIP-712 签名摘要
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        // 使用 ecrecover 恢复签名地址
        address recoveredAddress = ecrecover(digest, v, r, s);
        // 确保恢复的地址有效且与所有者地址一致
        require(recoveredAddress != address(0) && recoveredAddress == owner, "UniswapV2: INVALID_SIGNATURE");
        // 批准代币转移
        _approve(owner, spender, value);
    }
}
