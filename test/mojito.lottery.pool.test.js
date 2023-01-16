/*
* Node Version: V12.3+
* File Name: mojito.lottery.pool.test
* Author: neo
* Date Created: 2023-01-16
*/

const {
          accounts,
          contract,
      }                 = require("@openzeppelin/test-environment");
const {
          BN,
          expectEvent,
          expectRevert,
          constants,
          time,
      }                 = require("@openzeppelin/test-helpers");
const {expect}          = require("chai");
const MojitoToken       = contract.fromArtifact("MojitoToken");
const MojitoLotteryPool = contract.fromArtifact("MojitoLotteryPool");
const MojitoLotteryMock = contract.fromArtifact("MojitoLotteryMock");

describe("MojitoLotteryPool", () => {
    const [caller, operator, other] = accounts;
    const MojitoPerBlock            = new BN("3");
    before(async () => {
        this.mojito = await MojitoToken.new({from: caller});
        this.erc20  = await MojitoToken.new({from: caller});

        this.lottery1 = await MojitoLotteryMock.new(this.mojito.address, {from: caller});
        this.lottery2 = await MojitoLotteryMock.new(this.mojito.address, {from: caller});

        this.lotteryPool = await MojitoLotteryPool.new(this.mojito.address, MojitoPerBlock, 0, {from: caller});

        await this.erc20.grantRole(await this.mojito.MINTER_ROLE(), caller, {from: caller});
        await this.mojito.grantRole(await this.mojito.MINTER_ROLE(), caller, {from: caller});
        await this.mojito.grantRole(await this.mojito.MINTER_ROLE(), this.lotteryPool.address, {from: caller});

        await this.erc20.mint(other, new BN("100"), {from: caller});
        await this.mojito.mint(operator, new BN("100"), {from: caller});
        await this.mojito.mint(other, new BN("100"), {from: caller});

        await this.mojito.approve(this.lotteryPool.address, constants.MAX_UINT256, {from: operator});
        await this.mojito.approve(this.lotteryPool.address, constants.MAX_UINT256, {from: other});
    });

    it("setOperator(not owner)", async () => {
        await expectRevert(this.lotteryPool.setOperator(operator, {from: other}), "Ownable: caller is not the owner");
    });

    it("setOperator(zero address)", async () => {
        await expectRevert(this.lotteryPool.setOperator(constants.ZERO_ADDRESS, {from: caller}), "zero address");
    });

    it("setOperator()", async () => {
        expectEvent(
            await this.lotteryPool.setOperator(operator, {from: caller}),
            "OperatorUpdate",
            {
                from: constants.ZERO_ADDRESS,
                to:   operator,
            },
        );
    });

    it("add(not owner)", async () => {
        await expectRevert(
            this.lotteryPool.add(this.lottery1.address, new BN("100"), true, {from: other}),
            "Ownable: caller is not the owner",
        );
    });

    it("add()", async () => {
        await this.lotteryPool.add(this.lottery1.address, new BN("10"), true, {from: caller});
        await this.lotteryPool.add(this.lottery2.address, new BN("100"), true, {from: caller});

        expect(await this.mojito.allowance(this.lotteryPool.address, this.lottery1.address)).to.be.bignumber.equal(constants.MAX_UINT256);
        expect(await this.mojito.allowance(this.lotteryPool.address, this.lottery2.address)).to.be.bignumber.equal(constants.MAX_UINT256);

        expect(await this.lotteryPool.poolLength()).to.be.bignumber.equal(new BN("2"));
        expect(await this.lotteryPool.totalAllocPoint()).to.be.bignumber.equal(new BN("110"));

        const pool0 = await this.lotteryPool.poolInfo(0);
        const pool1 = await this.lotteryPool.poolInfo(1);
        expect(pool0.lottery).to.be.equal(this.lottery1.address);
        expect(pool0.allocPoint).to.be.bignumber.equal(new BN("10"));

        expect(pool1.lottery).to.be.equal(this.lottery2.address);
        expect(pool1.allocPoint).to.be.bignumber.equal(new BN("100"));
    });

    it("add(existing pool)", async () => {
        await expectRevert(
            this.lotteryPool.add(this.lottery1.address, new BN("100"), true, {from: caller}),
            "existing pool",
        );
    });

    it("set(not owner)", async () => {
        await expectRevert(
            this.lotteryPool.set(0, new BN("100"), {from: other}),
            "Ownable: caller is not the owner",
        );
    });

    it("set()", async () => {
        const {receipt} = await this.lotteryPool.set(0, new BN("100"), {from: caller});

        expect(await this.lotteryPool.totalAllocPoint()).to.be.bignumber.equal(new BN("200"));
        const pool = await this.lotteryPool.poolInfo("0");
        expect(pool.lottery).to.be.equal(this.lottery1.address);
        expect(pool.allocPoint).to.be.bignumber.equal(new BN("100"));
        expect(pool.lastRewardBlock).to.be.bignumber.equal(new BN(receipt.blockNumber));
    });

    it("poolInfo()", async () => {
        const pool0   = await this.lotteryPool.poolInfo(0);
        const pool1   = await this.lotteryPool.poolInfo(1);
        const balance = await this.mojito.balanceOf(this.lotteryPool.address);
        expect(pool0.pendingAmount.add(pool1.pendingAmount)).to.be.bignumber.equal(balance);
    });

    it("injectPending()", async () => {
        const poolBefore    = await this.lotteryPool.poolInfo(0);
        const balanceBefore = await this.mojito.balanceOf(this.lotteryPool.address);
        expectEvent(
            await this.lotteryPool.injectPending(0, new BN("10"), {from: other}),
            "InjectPending",
            {
                pid:    new BN("0"),
                amount: new BN("10"),
            },
        );

        const poolAfter    = await this.lotteryPool.poolInfo(0);
        const balanceAfter = await this.mojito.balanceOf(this.lotteryPool.address);
        expect(balanceAfter.sub(balanceBefore)).to.be.bignumber.equal(new BN("10"));
        expect(poolAfter.pendingAmount.sub(poolBefore.pendingAmount)).to.be.bignumber.equal(new BN("10"));
    });

    it("injectPool(not owner/operator)", async () => {
        await expectRevert(
            this.lotteryPool.injectPool(0, true, {from: other}),
            "not owner or operator",
        );
    });

    it("injectPool(0, false)", async () => {
        const pool      = await this.lotteryPool.poolInfo(0);
        const lotteryId = await this.lottery1.viewCurrentLotteryId();
        expectEvent(
            await this.lotteryPool.injectPool(0, false, {from: caller}),
            "InjectPool",
            {
                pid:       new BN("0"),
                lotteryId: lotteryId,
                amount:    pool.pendingAmount,
            },
        );

        const poolAfter = await this.lotteryPool.poolInfo(0);
        expect(poolAfter.pendingAmount).to.be.bignumber.equal(new BN("0"));
        expect(poolAfter.totalInject).to.be.bignumber.equal(pool.pendingAmount);
        expect(await this.lotteryPool.injectInfo(0, lotteryId)).to.be.bignumber.equal(pool.pendingAmount);
    });

    it("injectPool(1, true)", async () => {
        const pool      = await this.lotteryPool.poolInfo(1);
        const lotteryId = await this.lottery2.viewCurrentLotteryId();

        const {receipt}    = await this.lotteryPool.injectPool(1, true, {from: operator});
        const blockReward  = MojitoPerBlock.mul(new BN(receipt.blockNumber).sub(pool.lastRewardBlock));
        const mojitoReward = pool.allocPoint.mul(blockReward).div(await this.lotteryPool.totalAllocPoint());

        expectEvent(
            receipt,
            "InjectPool",
            {
                pid:       new BN("1"),
                lotteryId: lotteryId,
                amount:    pool.pendingAmount.add(mojitoReward),
            },
        );

        const poolAfter = await this.lotteryPool.poolInfo(1);
        expect(poolAfter.pendingAmount).to.be.bignumber.equal(new BN("0"));
        expect(poolAfter.totalInject).to.be.bignumber.equal(pool.pendingAmount.add(mojitoReward));
        expect(await this.lotteryPool.injectInfo(1, lotteryId)).to.be.bignumber.equal(pool.pendingAmount.add(mojitoReward));
    });

    it("advanceBlock(+20)", async () => {
        await this.mojito.transfer(this.lotteryPool.address, new BN("10"), {from: other});
        await this.erc20.transfer(this.lotteryPool.address, new BN("100"), {from: other});

        const latest = await time.latestBlock();
        await time.advanceBlock(latest.add(new BN("20")));
    });

    it("massUpdatePools()", async () => {
        const {receipt} = await this.lotteryPool.massUpdatePools();

        const pool0 = await this.lotteryPool.poolInfo(0);
        const pool1 = await this.lotteryPool.poolInfo(1);

        expect(pool0.lastRewardBlock).to.be.bignumber.equal(new BN(receipt.blockNumber));
        expect(pool1.lastRewardBlock).to.be.bignumber.equal(new BN(receipt.blockNumber));
    });

    it("totalPending()", async () => {
        const balance = await this.mojito.balanceOf(this.lotteryPool.address);

        const pool0 = await this.lotteryPool.poolInfo(0);
        const pool1 = await this.lotteryPool.poolInfo(1);

        const totalPending = pool0.pendingAmount.add(pool1.pendingAmount);
        expect(totalPending).to.be.bignumber.equal(await this.lotteryPool.totalPending());
        expect(totalPending).to.be.bignumber.equal(balance.sub(new BN("10")));
    });

    it("withdrawExtraToken(not owner)", async () => {
        await expectRevert(
            this.lotteryPool.withdrawExtraToken({from: operator}),
            "Ownable: caller is not the owner",
        );
    });

    it("recoverWrongTokens(not owner)", async () => {
        await expectRevert(
            this.lotteryPool.recoverWrongTokens(this.erc20.address, 0, {from: operator}),
            "Ownable: caller is not the owner",
        );
    });

    it("withdrawExtraToken()", async () => {
        expectEvent(
            await this.lotteryPool.withdrawExtraToken({from: caller}),
            "AdminTokenRecovery",
            {
                token:  this.mojito.address,
                amount: new BN("10"),
            },
        );

        const balance = await this.mojito.balanceOf(this.lotteryPool.address);
        expect(await this.lotteryPool.totalPending()).to.be.bignumber.equal(balance);
    });

    it("recoverWrongTokens", async () => {
        const balance = await this.erc20.balanceOf(this.lotteryPool.address);
        expectEvent(
            await this.lotteryPool.recoverWrongTokens(this.erc20.address, balance, {from: caller}),
            "AdminTokenRecovery",
            {
                token:  this.erc20.address,
                amount: balance,
            },
        );

        expect(balance).to.be.bignumber.equal(new BN("100"));
        expect(await this.erc20.balanceOf(this.lotteryPool.address)).to.be.bignumber.equal(new BN("0"));
    });
});

