const { expect } = require("chai");
const { ethers } = require("hardhat");
const BigNumber = require('bignumber.js');

describe("StakingMethods", function() {

    let stripToken;
    let stakingMethods;
    let owner;
    let addr1;
    let addr2;
    let addr3;

    beforeEach(async function () {
        [owner, addr1, addr2, addr3] = await ethers.getSigners();
        const StripToken = await ethers.getContractFactory("StripToken");
        stripToken = await StripToken.deploy();
        const StakingMethods = await ethers.getContractFactory("StakingMethods");
        stakingMethods = await StakingMethods.deploy(stripToken.address);
    });

    it("stake", async function() {
        await stripToken.approve(stakingMethods.address,'5000000000000000000000');
        await stakingMethods.stake('5000000000000000000000');
        const data = await stakingMethods.minTokenStake();
        console.log(data.toString());
    });
   
});