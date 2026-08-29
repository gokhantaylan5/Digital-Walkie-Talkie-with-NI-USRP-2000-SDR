% =========================================================
% HALF DUPLEX 2-FSK DIGITAL WALKIE TALKIE
% SIMPLIFIED METRICS + OUTAGE PROBABILITY + EYE DIAGRAM
% FIXED SPACE KEY TX CONTROL
% =========================================================
clear;
clc;
close all;

%% =========================================================
%% SDR SETTINGS
%% =========================================================
serialStr = "31C957E";
rfCenterFreq_Hz = 2.45e9;
fs_Sps = 400e3;
txGain_dB = 70;
rxGain_dB = 60;
masterClock = 20e6;
interp = round(masterClock / fs_Sps);
decim  = round(masterClock / fs_Sps);

%% =========================================================
%% AUDIO SETTINGS
%% =========================================================
audio_fs = 8000;
audio_duration = 0.05;
samplesPerFrame = round(audio_fs * audio_duration);

mic = audioDeviceReader( ...
    'SampleRate', audio_fs, ...
    'SamplesPerFrame', samplesPerFrame);
speaker = audioDeviceWriter( ...
    'SampleRate', audio_fs);

%% =========================================================
%% MODEM SETTINGS
%% =========================================================
bitRate_bps = 50e3;
sps = round(fs_Sps / bitRate_bps);
fDev = 35e3;
txAmplitude = 0.70;

%% =========================================================
%% SDR OBJECTS
%% =========================================================
tx = comm.SDRuTransmitter( ...
    'Platform',"B200", ...
    'SerialNum',serialStr, ...
    'CenterFrequency',rfCenterFreq_Hz, ...
    'Gain',txGain_dB, ...
    'MasterClockRate',masterClock, ...
    'InterpolationFactor',interp);

rx = comm.SDRuReceiver( ...
    'Platform',"B200", ...
    'SerialNum',serialStr, ...
    'CenterFrequency',rfCenterFreq_Hz, ...
    'Gain',rxGain_dB, ...
    'MasterClockRate',masterClock, ...
    'DecimationFactor',decim, ...
    'SamplesPerFrame',round(fs_Sps * 0.04), ...
    'OutputDataType',"double");

%% =========================================================
%% PACKET SETTINGS
%% =========================================================
barker13 = [1 1 1 1 1 0 0 1 1 0 1 0 1].';
preambleBits = repmat(barker13,4,1);
numPreambleBits = length(preambleBits);

rng(42);
testBits = randi([0 1],16,1);
numTestBits = length(testBits);
voiceFlagRepeat = 32;

totalFrameBits = round(bitRate_bps * audio_duration);
audioPayloadBits = ...
    totalFrameBits ...
    - numPreambleBits ...
    - numTestBits ...
    - voiceFlagRepeat;

preRef = 2 * double(preambleBits) - 1;

%% =========================================================
%% METRICS SETTINGS
%% =========================================================
uiUpdateHz = 3;
uiUpdatePeriod_sec = 1 / uiUpdateHz;

metrics.startTic = tic;
metrics.txFrames = 0;
metrics.rxDetectedFrames = 0;
metrics.rxValidAudioFrames = 0;
metrics.rxMutedFrames = 0;
metrics.rxNoPreamble = 0;
metrics.rxEmptyReads = 0;
metrics.rxOutageFrames = 0;

metrics.lastMode = 'IDLE';
metrics.status = 'WAITING';
metrics.micLevel = NaN;
metrics.voxOpen = false;
metrics.voiceTX = false;

metrics.ber = NaN;
metrics.outageProb = NaN;
metrics.instantOutage = NaN;
metrics.bitErrors = NaN;
metrics.isOutage = false;
metrics.numTestBits = numTestBits;

metrics.snrDb = NaN;
metrics.peak = NaN;
metrics.rxPowerDb = NaN;

metrics.voiceDetected = false;
metrics.validAudio = false;
metrics.validSamples = 0;

metrics.payloadBits = audioPayloadBits;
metrics.frameBits = totalFrameBits;
metrics.sps = sps;
metrics.bitRate = bitRate_bps;
metrics.fDev = fDev;
metrics.elapsedSec = 0;

metrics.txInstantThroughputBps = 0;
metrics.rxInstantFrameThroughputBps = 0;
metrics.rxInstantGoodputBps = 0;
metrics.txAvgThroughputBps = 0;
metrics.rxAvgFrameThroughputBps = 0;
metrics.rxAvgGoodputBps = 0;
metrics.channelUtilizationPct = 0;

metrics.maxHistory = 250;
metrics.sampleIndex = 0;
metrics.xHistory = [];
metrics.berHistory = [];
metrics.outageProbHistory = [];
metrics.instantOutageHistory = [];
metrics.snrHistory = [];
metrics.peakHistory = [];
metrics.rxPowerHistory = [];
metrics.txAvgThroughputHistory = [];
metrics.rxAvgFrameThroughputHistory = [];
metrics.rxAvgGoodputHistory = [];
metrics.rxInstantGoodputHistory = [];

%% =========================================================
%% EYE DIAGRAM SETTINGS
%% =========================================================
metrics.eyeSps = sps;
metrics.eyeSpanSymbols = 2;
metrics.eyeMaxTraces = 35;
metrics.eyeMaxSamples = metrics.eyeMaxTraces * metrics.eyeSpanSymbols * sps * 4;
metrics.eyeBuffer = [];

%% =========================================================
%% VOX SETTINGS
%% =========================================================
voiceOpenThreshold  = 0.012;
voiceCloseThreshold = 0.006;
hangFrames = 8;
voxOpen = false;
hangCounter = 0;

%% =========================================================
%% TX DELTA MOD
%% =========================================================
deltaPredTX = 0;
deltaStepTX = 0.020;
deltaStepMin = 0.004;
deltaStepMax = 0.040;
lastBitTX = 0;
phase = 0;

%% =========================================================
%% RX DELTA MOD
%% =========================================================
deltaPredRX = 0;
deltaStepRX = 0.020;
lastBitRX = 0;

%% =========================================================
%% RX FILTERS
%% =========================================================
[bLP, aLP] = butter(4, 3400/(audio_fs/2), 'low');
zLP = zeros(max(length(aLP), length(bLP)) - 1, 1);
[bHP, aHP] = butter(2, 90/(audio_fs/2), 'high');
zHP = zeros(max(length(aHP), length(bHP)) - 1, 1);

%% =========================================================
%% RX STATE
%% =========================================================
prevSample = complex(1,0);
demodBuffer = [];
minPeak = 0.55;
maxTestBERForAudio = 0.15;
minSnrForAudio_dB = 3;

%% =========================================================
%% UI
%% =========================================================
global pttPressed;
global pttStatusText;
global pttToggleButton;
pttPressed = false;

f = figure( ...
    'Name','HALF DUPLEX WALKIE TALKIE - CLEAN METRICS', ...
    'WindowKeyPressFcn',@keyDown, ...
    'WindowKeyReleaseFcn',@keyUp);
set(f,'Position',[40 40 1350 780]);

uicontrol( ...
    'Parent',f, ...
    'Style','text', ...
    'String','Click this window once, then hold SPACE to talk', ...
    'FontSize',12, ...
    'HorizontalAlignment','left', ...
    'Position',[20 20 390 30]);

pttToggleButton = uicontrol( ...
    'Parent',f, ...
    'Style','togglebutton', ...
    'String','TALK OFF', ...
    'FontSize',12, ...
    'Position',[20 55 130 35], ...
    'Callback',@pttToggleChanged);

pttStatusText = uicontrol( ...
    'Parent',f, ...
    'Style','text', ...
    'String','PTT: OFF', ...
    'FontSize',12, ...
    'FontWeight','bold', ...
    'HorizontalAlignment','left', ...
    'Position',[170 55 220 35]);

metricText = uicontrol( ...
    'Parent',f, ...
    'Style','text', ...
    'String','Metrics initializing...', ...
    'FontSize',9, ...
    'FontName','Consolas', ...
    'HorizontalAlignment','left', ...
    'Position',[20 100 400 620]);

%% =========================================================
%% LIVE GRAPH PANEL
%% =========================================================
graphPanel = uipanel( ...
    'Parent',f, ...
    'Title','Clean Live Metrics', ...
    'FontSize',11, ...
    'Position',[0.33 0.06 0.65 0.90]);

tile = tiledlayout(graphPanel,3,2, ...
    'TileSpacing','compact', ...
    'Padding','compact');

axBEROutage = nexttile(tile,1);
hold(axBEROutage,'on');
berLine = plot(axBEROutage, NaN, NaN, 'LineWidth',1.3);
outageProbLine = plot(axBEROutage, NaN, NaN, 'LineWidth',1.3);
instantOutageLine = plot(axBEROutage, NaN, NaN, 'LineWidth',1.0);
hold(axBEROutage,'off');
grid(axBEROutage,'on');
title(axBEROutage,'BER / Outage Probability');
xlabel(axBEROutage,'Update');
ylabel(axBEROutage,'Rate');
ylim(axBEROutage,[0 1]);
legend(axBEROutage, ...
    {'BER','Outage Prob','Instant Outage'}, ...
    'Location','southoutside', ...
    'Orientation','horizontal');

axSNR = nexttile(tile,2);
snrLine = plot(axSNR, NaN, NaN, 'LineWidth',1.3);
grid(axSNR,'on');
title(axSNR,'SNR Estimate');
xlabel(axSNR,'Update');
ylabel(axSNR,'dB');

axPeak = nexttile(tile,3);
peakLine = plot(axPeak, NaN, NaN, 'LineWidth',1.3);
grid(axPeak,'on');
title(axPeak,'Preamble Peak');
xlabel(axPeak,'Update');
ylabel(axPeak,'Peak');
ylim(axPeak,[0 1]);

axRxPower = nexttile(tile,4);
rxPowerLine = plot(axRxPower, NaN, NaN, 'LineWidth',1.3);
grid(axRxPower,'on');
title(axRxPower,'RX Power Estimate');
xlabel(axRxPower,'Update');
ylabel(axRxPower,'dB');

axThroughput = nexttile(tile,5);
hold(axThroughput,'on');
txAvgThroughputLine = plot(axThroughput, NaN, NaN, 'LineWidth',1.2);
rxAvgFrameThroughputLine = plot(axThroughput, NaN, NaN, 'LineWidth',1.2);
rxAvgGoodputLine = plot(axThroughput, NaN, NaN, 'LineWidth',1.2);
rxInstantGoodputLine = plot(axThroughput, NaN, NaN, 'LineWidth',1.2);
hold(axThroughput,'off');
grid(axThroughput,'on');
title(axThroughput,'Throughput / Goodput');
xlabel(axThroughput,'Update');
ylabel(axThroughput,'bps');
legend(axThroughput, ...
    {'TX Avg','RX Frame Avg','RX Goodput Avg','RX Goodput Inst'}, ...
    'Location','southoutside', ...
    'Orientation','horizontal');

axEye = nexttile(tile,6);
hold(axEye,'on');
eyeLineHandles = gobjects(metrics.eyeMaxTraces,1);
for ii = 1:metrics.eyeMaxTraces
    eyeLineHandles(ii) = plot(axEye, NaN, NaN, 'LineWidth',0.6);
end
hold(axEye,'off');
grid(axEye,'on');
title(axEye,'Eye Diagram');
xlabel(axEye,'Symbol Periods');
ylabel(axEye,'Demod Metric');
xlim(axEye,[0 metrics.eyeSpanSymbols]);

plotHandles.berLine = berLine;
plotHandles.outageProbLine = outageProbLine;
plotHandles.instantOutageLine = instantOutageLine;
plotHandles.snrLine = snrLine;
plotHandles.peakLine = peakLine;
plotHandles.rxPowerLine = rxPowerLine;
plotHandles.txAvgThroughputLine = txAvgThroughputLine;
plotHandles.rxAvgFrameThroughputLine = rxAvgFrameThroughputLine;
plotHandles.rxAvgGoodputLine = rxAvgGoodputLine;
plotHandles.rxInstantGoodputLine = rxInstantGoodputLine;
plotHandles.eyeLineHandles = eyeLineHandles;

plotHandles.axBEROutage = axBEROutage;
plotHandles.axSNR = axSNR;
plotHandles.axPeak = axPeak;
plotHandles.axRxPower = axRxPower;
plotHandles.axThroughput = axThroughput;
plotHandles.axEye = axEye;

lastUiUpdate = tic;
[metrics,lastUiUpdate] = commitMetrics( ...
    metricText, ...
    plotHandles, ...
    metrics, ...
    lastUiUpdate, ...
    uiUpdatePeriod_sec, ...
    true);

disp("Önce figure penceresine bir kez tıkla.");
disp("SPACE basılı tut = konuş");
disp("SPACE bırak = dinle");
disp("Space çalışmazsa TALK OFF / TALK ON butonunu kullan.");
disp("SDR akışı bozulursa uiUpdateHz değerini 2 yap.");

%% =========================================================
%% MAIN LOOP
%% =========================================================
try
while ishandle(f)
    drawnow limitrate;
    
    %% =====================================================
    %% TX MODE
    %% =====================================================
    if pttPressed
        audio = mic();
        audio = audio - mean(audio);
        micLevel = rms(audio);
        
        if ~voxOpen
            if micLevel > voiceOpenThreshold
                voxOpen = true;
                hangCounter = hangFrames;
            end
        else
            if micLevel > voiceCloseThreshold
                hangCounter = hangFrames;
            else
                hangCounter = hangCounter - 1;
                if hangCounter <= 0
                    voxOpen = false;
                end
            end
        end
        
        if voxOpen
            voiceFlagBits = ones(voiceFlagRepeat,1);
            audio = audio * 4;
            audio = max(min(audio,1),-1);
            audioHigh = resample( ...
                audio, ...
                audioPayloadBits, ...
                samplesPerFrame);
            audioHigh = audioHigh(:);
            
            deltaBits = zeros(audioPayloadBits,1);
            for n = 1:audioPayloadBits
                if audioHigh(n) >= deltaPredTX
                    bitNow = 1;
                    deltaPredTX = deltaPredTX + deltaStepTX;
                else
                    bitNow = 0;
                    deltaPredTX = deltaPredTX - deltaStepTX;
                end
                
                if bitNow == lastBitTX
                    deltaStepTX = min(deltaStepTX * 1.08, deltaStepMax);
                else
                    deltaStepTX = max(deltaStepTX * 0.92, deltaStepMin);
                end
                lastBitTX = bitNow;
                deltaPredTX = deltaPredTX * 0.998;
                deltaPredTX = max(min(deltaPredTX,1),-1);
                deltaBits(n) = bitNow;
            end
        else
            voiceFlagBits = zeros(voiceFlagRepeat,1);
            deltaPredTX = 0;
            deltaStepTX = 0.020;
            lastBitTX = 0;
            deltaBits = zeros(audioPayloadBits,1);
        end
        
        frameBits = [
            preambleBits;
            testBits;
            voiceFlagBits;
            deltaBits
        ];
        
        freqBits = (2 * double(frameBits) - 1) * fDev;
        freqSamples = repelem(freqBits,sps);
        
        phaseInc = 2*pi*freqSamples/fs_Sps;
        phaseVec = cumsum(phaseInc) + phase;
        sig = txAmplitude * exp(1j * phaseVec);
        phase = mod(phaseVec(end),2*pi);
        
        tx(sig);
        
        metrics.txFrames = metrics.txFrames + 1;
        metrics.lastMode = 'TX';
        metrics.status = 'TRANSMITTING';
        metrics.micLevel = micLevel;
        metrics.voxOpen = voxOpen;
        metrics.voiceTX = any(voiceFlagBits);
        
        metrics.ber = NaN;
        metrics.instantOutage = NaN;
        metrics.bitErrors = NaN;
        metrics.isOutage = false;
        metrics.snrDb = NaN;
        metrics.peak = NaN;
        metrics.voiceDetected = false;
        metrics.validAudio = false;
        metrics.validSamples = 0;
        
        metrics.txInstantThroughputBps = totalFrameBits / audio_duration;
        metrics.rxInstantFrameThroughputBps = 0;
        metrics.rxInstantGoodputBps = 0;
        
        [metrics,lastUiUpdate] = commitMetrics( ...
            metricText, ...
            plotHandles, ...
            metrics, ...
            lastUiUpdate, ...
            uiUpdatePeriod_sec, ...
            false);
            
    %% =====================================================
    %% RX MODE
    %% =====================================================
    else
        [rxData, validSamples] = rx();
        
        metrics.txInstantThroughputBps = 0;
        metrics.rxInstantFrameThroughputBps = 0;
        metrics.rxInstantGoodputBps = 0;
        
        if validSamples <= 0
            metrics.rxEmptyReads = metrics.rxEmptyReads + 1;
            metrics.lastMode = 'RX';
            metrics.status = 'NO SDR SAMPLES';
            metrics.validSamples = validSamples;
            metrics.voiceTX = false;
            metrics.voxOpen = voxOpen;
            metrics.instantOutage = NaN;
            metrics.isOutage = false;
            
            [metrics,lastUiUpdate] = commitMetrics( ...
                metricText, ...
                plotHandles, ...
                metrics, ...
                lastUiUpdate, ...
                uiUpdatePeriod_sec, ...
                false);
            continue;
        end
        
        metrics.validSamples = validSamples;
        metrics.rxPowerDb = 10*log10(mean(abs(rxData).^2) + 1e-12);
        metrics.voiceTX = false;
        metrics.voxOpen = voxOpen;
        
        rxData = rxData - mean(rxData);
        x = [prevSample; rxData];
        demod = angle(x(2:end) .* conj(x(1:end-1)));
        prevSample = rxData(end);
        
        demod = demod - mean(demod);
        demodBuffer = [demodBuffer; demod];
        
        maxBufferSamples = totalFrameBits * sps * 4;
        if length(demodBuffer) > maxBufferSamples
            demodBuffer = demodBuffer(end-maxBufferSamples+1:end);
        end
        
        if length(demodBuffer) < totalFrameBits * sps
            metrics.lastMode = 'RX';
            metrics.status = 'BUFFERING';
            metrics.peak = NaN;
            metrics.validAudio = false;
            metrics.voiceDetected = false;
            metrics.instantOutage = NaN;
            metrics.isOutage = false;
            
            [metrics,lastUiUpdate] = commitMetrics( ...
                metricText, ...
                plotHandles, ...
                metrics, ...
                lastUiUpdate, ...
                uiUpdatePeriod_sec, ...
                false);
            continue;
        end
        
        bestPeak = -inf;
        bestBits = [];
        bestMetric = [];
        bestTau = 0;
        bestStart = 0;
        bestPolarity = 1;
        
        for tau = 0:sps-1
            usableLen = floor((length(demodBuffer)-tau)/sps);
            if usableLen < totalFrameBits
                continue;
            end
            
            bitMetric = zeros(usableLen,1);
            for k = 1:usableLen
                idx1 = tau + (k-1)*sps + 1;
                idx2 = idx1 + sps - 1;
                bitMetric(k) = mean(demodBuffer(idx1:idx2));
            end
            
            bitMetric = bitMetric - mean(bitMetric);
            bipolar0 = sign(bitMetric);
            bipolar0(bipolar0 == 0) = 1;
            bipolar1 = -bipolar0;
            
            corr0 = conv(bipolar0, flipud(preRef), 'valid') / numPreambleBits;
            corr1 = conv(bipolar1, flipud(preRef), 'valid') / numPreambleBits;
            
            [p0,i0] = max(corr0);
            [p1,i1] = max(corr1);
            
            if p0 > bestPeak
                bestPeak = p0;
                bestTau = tau;
                bestStart = i0;
                bestMetric = bitMetric;
                bestBits = bipolar0 > 0;
                bestPolarity = 1;
            end
            if p1 > bestPeak
                bestPeak = p1;
                bestTau = tau;
                bestStart = i1;
                bestMetric = -bitMetric;
                bestBits = bipolar1 > 0;
                bestPolarity = -1;
            end
        end
        
        if bestPeak < minPeak || isempty(bestBits)
            metrics.rxNoPreamble = metrics.rxNoPreamble + 1;
            metrics.lastMode = 'RX';
            metrics.status = 'NO PREAMBLE';
            metrics.peak = bestPeak;
            metrics.ber = NaN;
            metrics.instantOutage = NaN;
            metrics.bitErrors = NaN;
            metrics.isOutage = false;
            metrics.snrDb = NaN;
            metrics.voiceDetected = false;
            metrics.validAudio = false;
            metrics.rxInstantFrameThroughputBps = 0;
            metrics.rxInstantGoodputBps = 0;
            
            [metrics,lastUiUpdate] = commitMetrics( ...
                metricText, ...
                plotHandles, ...
                metrics, ...
                lastUiUpdate, ...
                uiUpdatePeriod_sec, ...
                false);
            speaker(zeros(round(audio_fs * audio_duration),1));
            continue;
        end
        
        frameStart = bestStart;
        frameEnd = frameStart + totalFrameBits - 1;
        
        if frameEnd > length(bestBits)
            metrics.lastMode = 'RX';
            metrics.status = 'FRAME END OUT OF RANGE';
            metrics.validAudio = false;
            metrics.rxInstantFrameThroughputBps = 0;
            metrics.rxInstantGoodputBps = 0;
            
            [metrics,lastUiUpdate] = commitMetrics( ...
                metricText, ...
                plotHandles, ...
                metrics, ...
                lastUiUpdate, ...
                uiUpdatePeriod_sec, ...
                false);
            continue;
        end
        
        eyeStart = bestTau + (frameStart-1)*sps + 1;
        eyeEnd = bestTau + frameEnd*sps;
        if eyeStart >= 1 && eyeEnd <= length(demodBuffer)
            newEyeSamples = bestPolarity * demodBuffer(eyeStart:eyeEnd);
            metrics.eyeBuffer = [metrics.eyeBuffer; newEyeSamples(:)];
            if length(metrics.eyeBuffer) > metrics.eyeMaxSamples
                metrics.eyeBuffer = metrics.eyeBuffer(end-metrics.eyeMaxSamples+1:end);
            end
        end
        
        rxFrameBits = bestBits(frameStart:frameEnd);
        metrics.rxDetectedFrames = metrics.rxDetectedFrames + 1;
        metrics.rxInstantFrameThroughputBps = totalFrameBits / audio_duration;
        
        rxFrameMetric = bestMetric(frameStart:frameEnd);
        
        consumeSamples = bestTau + frameEnd * sps;
        if consumeSamples > 0 && consumeSamples < length(demodBuffer)
            demodBuffer = demodBuffer(consumeSamples+1:end);
        else
            demodBuffer = [];
        end
        
        rxTestBits = rxFrameBits(numPreambleBits+1 : numPreambleBits+numTestBits);
        bitErrors = sum(rxTestBits ~= testBits);
        ber = bitErrors / numTestBits;
        metrics.ber = ber;
        metrics.bitErrors = bitErrors;
        
        testMetric = rxFrameMetric(numPreambleBits+1 : numPreambleBits+numTestBits);
        m1 = testMetric(testBits == 1);
        m0 = testMetric(testBits == 0);
        
        if ~isempty(m1) && ~isempty(m0)
            mu1 = mean(m1);
            mu0 = mean(m0);
            sigma = sqrt((var(m1)+var(m0))/2) + 1e-12;
            snrLin = ((mu1-mu0)/(2*sigma))^2;
            snrDb = 10*log10(snrLin + 1e-12);
        else
            snrDb = 0;
        end
        metrics.snrDb = snrDb;
        
        isOutage = snrDb < minSnrForAudio_dB;
        metrics.instantOutage = double(isOutage);
        metrics.isOutage = isOutage;
        if isOutage
            metrics.rxOutageFrames = metrics.rxOutageFrames + 1;
        end
        metrics.outageProb = metrics.rxOutageFrames / max(metrics.rxDetectedFrames, 1);
        
        flagStart = numPreambleBits + numTestBits + 1;
        flagEnd = flagStart + voiceFlagRepeat - 1;
        rxVoiceFlags = rxFrameBits(flagStart:flagEnd);
        voiceDetected = mean(rxVoiceFlags) > 0.75;
        
        payloadStart = flagEnd + 1;
        payloadEnd = payloadStart + audioPayloadBits - 1;
        
        if payloadEnd > length(rxFrameBits)
            metrics.lastMode = 'RX';
            metrics.status = 'PAYLOAD OUT OF RANGE';
            metrics.validAudio = false;
            metrics.peak = bestPeak;
            metrics.voiceDetected = voiceDetected;
            metrics.rxInstantGoodputBps = 0;
            
            [metrics,lastUiUpdate] = commitMetrics( ...
                metricText, ...
                plotHandles, ...
                metrics, ...
                lastUiUpdate, ...
                uiUpdatePeriod_sec, ...
                false);
            continue;
        end
        
        payloadBits = rxFrameBits(payloadStart:payloadEnd);
        
        isValidAudioFrame = bestPeak >= minPeak && ber <= maxTestBERForAudio && ~isOutage && voiceDetected;
        
        if ~isValidAudioFrame
            metrics.rxMutedFrames = metrics.rxMutedFrames + 1;
            metrics.lastMode = 'RX';
            metrics.status = 'MUTED / INVALID FRAME';
            metrics.peak = bestPeak;
            metrics.voiceDetected = voiceDetected;
            metrics.validAudio = false;
            metrics.rxInstantGoodputBps = 0;
            
            [metrics,lastUiUpdate] = commitMetrics( ...
                metricText, ...
                plotHandles, ...
                metrics, ...
                lastUiUpdate, ...
                uiUpdatePeriod_sec, ...
                false);
                
            deltaPredRX = 0;
            deltaStepRX = 0.020;
            lastBitRX = 0;
            speaker(zeros(round(audio_fs * audio_duration),1));
            continue;
        end
        
        audioHigh = zeros(audioPayloadBits,1);
        for n = 1:audioPayloadBits
            bitNow = payloadBits(n);
            if bitNow
                deltaPredRX = deltaPredRX + deltaStepRX;
            else
                deltaPredRX = deltaPredRX - deltaStepRX;
            end
            
            if bitNow == lastBitRX
                deltaStepRX = min(deltaStepRX * 1.08, deltaStepMax);
            else
                deltaStepRX = max(deltaStepRX * 0.92, deltaStepMin);
            end
            lastBitRX = bitNow;
            deltaPredRX = deltaPredRX * 0.998;
            deltaPredRX = max(min(deltaPredRX,1),-1);
            audioHigh(n) = deltaPredRX;
        end
        
        audioOut = resample( ...
            audioHigh, ...
            round(audio_fs * audio_duration), ...
            audioPayloadBits);
            
        audioOut = audioOut - mean(audioOut);
        [audioOut,zHP] = filter(bHP,aHP,audioOut,zHP);
        [audioOut,zLP] = filter(bLP,aLP,audioOut,zLP);
        
        audioOut = audioOut * 1.8;
        audioOut = max(min(audioOut,0.9),-0.9);
        speaker(audioOut);
        
        metrics.rxValidAudioFrames = metrics.rxValidAudioFrames + 1;
        metrics.lastMode = 'RX';
        metrics.status = 'VALID AUDIO';
        metrics.peak = bestPeak;
        metrics.voiceDetected = voiceDetected;
        metrics.validAudio = true;
        metrics.rxInstantGoodputBps = audioPayloadBits / audio_duration;
        
        [metrics,lastUiUpdate] = commitMetrics( ...
            metricText, ...
            plotHandles, ...
            metrics, ...
            lastUiUpdate, ...
            uiUpdatePeriod_sec, ...
            false);
    end
end

catch ME
disp(ME.message);
end

release(tx);
release(rx);
release(mic);
release(speaker);

%% =========================================================
%% KEY CALLBACKS
%% =========================================================
function keyDown(~,event)
global pttPressed;
global pttStatusText;
global pttToggleButton;
if strcmp(event.Key,'space')
    pttPressed = true;
    if ishandle(pttStatusText)
        set(pttStatusText,'String','PTT: ON / TX MODE');
    end
    if ishandle(pttToggleButton)
        set(pttToggleButton,'Value',1);
        set(pttToggleButton,'String','TALK ON');
    end
end
end

function keyUp(~,event)
global pttPressed;
global pttStatusText;
global pttToggleButton;
if strcmp(event.Key,'space')
    pttPressed = false;
    if ishandle(pttStatusText)
        set(pttStatusText,'String','PTT: OFF / RX MODE');
    end
    if ishandle(pttToggleButton)
        set(pttToggleButton,'Value',0);
        set(pttToggleButton,'String','TALK OFF');
    end
end
end

function pttToggleChanged(src,~)
global pttPressed;
global pttStatusText;
pttPressed = logical(get(src,'Value'));
if pttPressed
    set(src,'String','TALK ON');
    if ishandle(pttStatusText)
        set(pttStatusText,'String','PTT: ON / TX MODE');
    end
else
    set(src,'String','TALK OFF');
    if ishandle(pttStatusText)
        set(pttStatusText,'String','PTT: OFF / RX MODE');
    end
end
end

%% =========================================================
%% COMMIT METRICS FUNCTION
%% =========================================================
function [metrics,lastUiUpdate] = commitMetrics( ...
    metricText, ...
    plotHandles, ...
    metrics, ...
    lastUiUpdate, ...
    uiUpdatePeriod_sec, ...
    forceUpdate)

metrics = updateThroughputMetrics(metrics);
metrics = appendMetricHistory(metrics);

if forceUpdate || toc(lastUiUpdate) >= uiUpdatePeriod_sec
    updateMetricPanel(metricText, metrics);
    updateMetricPlots(plotHandles, metrics);
    drawnow limitrate;
    lastUiUpdate = tic;
end
end

%% =========================================================
%% THROUGHPUT CALCULATION FUNCTION
%% =========================================================
function metrics = updateThroughputMetrics(metrics)
metrics.elapsedSec = toc(metrics.startTic);
elapsedSafe = max(metrics.elapsedSec, 1e-9);

metrics.txAvgThroughputBps = ...
    (metrics.txFrames * metrics.frameBits) / elapsedSafe;
metrics.rxAvgFrameThroughputBps = ...
    (metrics.rxDetectedFrames * metrics.frameBits) / elapsedSafe;
metrics.rxAvgGoodputBps = ...
    (metrics.rxValidAudioFrames * metrics.payloadBits) / elapsedSafe;
metrics.channelUtilizationPct = ...
    100 * metrics.rxAvgGoodputBps / max(metrics.bitRate, 1e-9);
end

%% =========================================================
%% METRIC HISTORY FUNCTION
%% =========================================================
function metrics = appendMetricHistory(metrics)
metrics.sampleIndex = metrics.sampleIndex + 1;
metrics.xHistory(end+1) = metrics.sampleIndex;
metrics.berHistory(end+1) = holdLastFinite(metrics.ber, metrics.berHistory);
metrics.outageProbHistory(end+1) = holdLastFinite(metrics.outageProb, metrics.outageProbHistory);
metrics.instantOutageHistory(end+1) = holdLastFinite(metrics.instantOutage, metrics.instantOutageHistory);
metrics.snrHistory(end+1) = holdLastFinite(metrics.snrDb, metrics.snrHistory);
metrics.peakHistory(end+1) = holdLastFinite(metrics.peak, metrics.peakHistory);
metrics.rxPowerHistory(end+1) = holdLastFinite(metrics.rxPowerDb, metrics.rxPowerHistory);
metrics.txAvgThroughputHistory(end+1) = holdLastFinite(metrics.txAvgThroughputBps, metrics.txAvgThroughputHistory);
metrics.rxAvgFrameThroughputHistory(end+1) = holdLastFinite(metrics.rxAvgFrameThroughputBps, metrics.rxAvgFrameThroughputHistory);
metrics.rxAvgGoodputHistory(end+1) = holdLastFinite(metrics.rxAvgGoodputBps, metrics.rxAvgGoodputHistory);
metrics.rxInstantGoodputHistory(end+1) = holdLastFinite(metrics.rxInstantGoodputBps, metrics.rxInstantGoodputHistory);

if length(metrics.xHistory) > metrics.maxHistory
    metrics.xHistory = trimHistory(metrics.xHistory, metrics.maxHistory);
    metrics.berHistory = trimHistory(metrics.berHistory, metrics.maxHistory);
    metrics.outageProbHistory = trimHistory(metrics.outageProbHistory, metrics.maxHistory);
    metrics.instantOutageHistory = trimHistory(metrics.instantOutageHistory, metrics.maxHistory);
    metrics.snrHistory = trimHistory(metrics.snrHistory, metrics.maxHistory);
    metrics.peakHistory = trimHistory(metrics.peakHistory, metrics.maxHistory);
    metrics.rxPowerHistory = trimHistory(metrics.rxPowerHistory, metrics.maxHistory);
    metrics.txAvgThroughputHistory = trimHistory(metrics.txAvgThroughputHistory, metrics.maxHistory);
    metrics.rxAvgFrameThroughputHistory = trimHistory(metrics.rxAvgFrameThroughputHistory, metrics.maxHistory);
    metrics.rxAvgGoodputHistory = trimHistory(metrics.rxAvgGoodputHistory, metrics.maxHistory);
    metrics.rxInstantGoodputHistory = trimHistory(metrics.rxInstantGoodputHistory, metrics.maxHistory);
end
end

function valueOut = holdLastFinite(valueIn, history)
if isfinite(valueIn)
    valueOut = valueIn;
else
    if isempty(history)
        valueOut = NaN;
    else
        valueOut = history(end);
    end
end
end

function out = trimHistory(in, maxHistory)
out = in(end-maxHistory+1:end);
end

%% =========================================================
%% METRIC PANEL FUNCTIONS
%% =========================================================
function updateMetricPanel(h, metrics)
if ~ishandle(h)
    return;
end

berStr = fmtMetric(metrics.ber, '%.4f');
outageProbStr = fmtMetric(metrics.outageProb * 100, '%.2f %%');
instantOutageStr = fmtMetric(metrics.instantOutage, '%.0f');
errStr = fmtMetric(metrics.bitErrors, '%.0f');
snrStr = fmtMetric(metrics.snrDb, '%.2f dB');
peakStr = fmtMetric(metrics.peak, '%.3f');
rxPowerStr = fmtMetric(metrics.rxPowerDb, '%.2f dB');

txAvgThroughputStr = fmtMetric(metrics.txAvgThroughputBps, '%.1f bps');
rxAvgFrameThroughputStr = fmtMetric(metrics.rxAvgFrameThroughputBps, '%.1f bps');
rxAvgGoodputStr = fmtMetric(metrics.rxAvgGoodputBps, '%.1f bps');
rxInstantGoodputStr = fmtMetric(metrics.rxInstantGoodputBps, '%.1f bps');
channelUtilStr = fmtMetric(metrics.channelUtilizationPct, '%.2f %%');
elapsedStr = fmtMetric(metrics.elapsedSec, '%.2f s');

panelText = sprintf([ ...
    'MODE                 : %s\n' ...
    'STATUS               : %s\n' ...
    'ELAPSED TIME         : %s\n' ...
    '\n' ...
    'TX FRAMES            : %d\n' ...
    'RX DETECTED FRAME    : %d\n' ...
    'RX OUTAGE FRAMES     : %d\n' ...
    'RX VALID AUDIO       : %d\n' ...
    'RX MUTED FRAME       : %d\n' ...
    'RX NO PREAMBLE       : %d\n' ...
    'RX EMPTY READS       : %d\n' ...
    '\n' ...
    'BER                  : %s\n' ...
    'OUTAGE PROB (<3dB)   : %s\n' ...
    'INSTANT OUTAGE       : %s\n' ...
    'BIT ERRORS           : %s / %d\n' ...
    'SNR ESTIMATE         : %s\n' ...
    'PREAMBLE PEAK        : %s\n' ...
    'RX POWER             : %s\n' ...
    '\n' ...
    'TX AVG THROUGHPUT    : %s\n' ...
    'RX FRAME THROUGHPUT  : %s\n' ...
    'RX AVG GOODPUT       : %s\n' ...
    'RX INSTANT GOODPUT   : %s\n' ...
    'CHANNEL UTILIZATION  : %s\n' ...
    '\n' ...
    'VOICE TX             : %s\n' ...
    'VOICE RX FLAG        : %s\n' ...
    'VALID AUDIO          : %s\n' ...
    'OUTAGE STATUS        : %s\n' ...
    'VOX OPEN             : %s\n' ...
    '\n' ...
    'VALID SDR SAMPLES    : %d\n' ...
    'FRAME BITS           : %d\n' ...
    'PAYLOAD BITS         : %d\n' ...
    'SPS                  : %d\n' ...
    'BIT RATE             : %.0f bps\n' ...
    'FREQ DEV             : %.0f Hz\n' ...
    '\n' ...
    'UI UPDATE RATE       : %.1f Hz limited\n' ...
    'GRAPH HISTORY        : %d samples\n' ...
    'EYE TRACES           : %d\n'], ...
    metrics.lastMode, ...
    metrics.status, ...
    elapsedStr, ...
    metrics.txFrames, ...
    metrics.rxDetectedFrames, ...
    metrics.rxOutageFrames, ...
    metrics.rxValidAudioFrames, ...
    metrics.rxMutedFrames, ...
    metrics.rxNoPreamble, ...
    metrics.rxEmptyReads, ...
    berStr, ...
    outageProbStr, ...
    instantOutageStr, ...
    errStr, ...
    metrics.numTestBits, ...
    snrStr, ...
    peakStr, ...
    rxPowerStr, ...
    txAvgThroughputStr, ...
    rxAvgFrameThroughputStr, ...
    rxAvgGoodputStr, ...
    rxInstantGoodputStr, ...
    channelUtilStr, ...
    boolText(metrics.voiceTX), ...
    boolText(metrics.voiceDetected), ...
    boolText(metrics.validAudio), ...
    boolText(metrics.isOutage), ...
    boolText(metrics.voxOpen), ...
    metrics.validSamples, ...
    metrics.frameBits, ...
    metrics.payloadBits, ...
    metrics.sps, ...
    metrics.bitRate, ...
    metrics.fDev, ...
    3.0, ...
    metrics.maxHistory, ...
    metrics.eyeMaxTraces);

set(h,'String',panelText);
end

function out = fmtMetric(value, fmt)
if isnan(value)
    out = 'N/A';
elseif isinf(value)
    out = 'N/A';
else
    out = sprintf(fmt, value);
end
end

function out = boolText(value)
if value
    out = 'YES';
else
    out = 'NO';
end
end

%% =========================================================
%% LIVE PLOT FUNCTIONS
%% =========================================================
function updateMetricPlots(plotHandles, metrics)

if ~ishandle(plotHandles.berLine)
    return;
end

x = metrics.xHistory;

set(plotHandles.berLine, ...
    'XData',x, ...
    'YData',metrics.berHistory);
set(plotHandles.outageProbLine, ...
    'XData',x, ...
    'YData',metrics.outageProbHistory);
set(plotHandles.instantOutageLine, ...
    'XData',x, ...
    'YData',metrics.instantOutageHistory);
    
set(plotHandles.snrLine, ...
    'XData',x, ...
    'YData',metrics.snrHistory);
set(plotHandles.peakLine, ...
    'XData',x, ...
    'YData',metrics.peakHistory);
set(plotHandles.rxPowerLine, ...
    'XData',x, ...
    'YData',metrics.rxPowerHistory);
    
set(plotHandles.txAvgThroughputLine, ...
    'XData',x, ...
    'YData',metrics.txAvgThroughputHistory);
set(plotHandles.rxAvgFrameThroughputLine, ...
    'XData',x, ...
    'YData',metrics.rxAvgFrameThroughputHistory);
set(plotHandles.rxAvgGoodputLine, ...
    'XData',x, ...
    'YData',metrics.rxAvgGoodputHistory);
set(plotHandles.rxInstantGoodputLine, ...
    'XData',x, ...
    'YData',metrics.rxInstantGoodputHistory);

updateEyeDiagram(plotHandles, metrics);

if ~isempty(x)
    xMin = max(1, x(end) - metrics.maxHistory);
    xMax = x(end) + 1;
    xlim(plotHandles.axBEROutage,[xMin xMax]);
    xlim(plotHandles.axSNR,[xMin xMax]);
    xlim(plotHandles.axPeak,[xMin xMax]);
    xlim(plotHandles.axRxPower,[xMin xMax]);
    xlim(plotHandles.axThroughput,[xMin xMax]);
end

validSNR = metrics.snrHistory(isfinite(metrics.snrHistory));
if ~isempty(validSNR)
    snrMin = min(validSNR) - 2;
    snrMax = max(validSNR) + 2;
    if snrMin == snrMax
        snrMin = snrMin - 1;
        snrMax = snrMax + 1;
    end
    ylim(plotHandles.axSNR,[snrMin snrMax]);
end

validRxPower = metrics.rxPowerHistory(isfinite(metrics.rxPowerHistory));
if ~isempty(validRxPower)
    pMin = min(validRxPower) - 3;
    pMax = max(validRxPower) + 3;
    if pMin == pMax
        pMin = pMin - 1;
        pMax = pMax + 1;
    end
    ylim(plotHandles.axRxPower,[pMin pMax]);
end

validThroughput = [
    metrics.txAvgThroughputHistory(isfinite(metrics.txAvgThroughputHistory)), ...
    metrics.rxAvgFrameThroughputHistory(isfinite(metrics.rxAvgFrameThroughputHistory)), ...
    metrics.rxAvgGoodputHistory(isfinite(metrics.rxAvgGoodputHistory)), ...
    metrics.rxInstantGoodputHistory(isfinite(metrics.rxInstantGoodputHistory))
];
if ~isempty(validThroughput)
    tMax = max(validThroughput) * 1.2;
    if tMax <= 0
        tMax = metrics.bitRate;
    end
    ylim(plotHandles.axThroughput,[0 tMax]);
end
end

%% =========================================================
%% EYE DIAGRAM UPDATE FUNCTION
%% =========================================================
function updateEyeDiagram(plotHandles, metrics)
if isempty(metrics.eyeBuffer)
    return;
end
if ~ishandle(plotHandles.eyeLineHandles(1))
    return;
end

traceLen = metrics.eyeSpanSymbols * metrics.eyeSps;
if length(metrics.eyeBuffer) < traceLen
    for ii = 1:length(plotHandles.eyeLineHandles)
        set(plotHandles.eyeLineHandles(ii), ...
            'XData',NaN, ...
            'YData',NaN);
    end
    return;
end

numPossibleTraces = floor((length(metrics.eyeBuffer) - traceLen) / metrics.eyeSps) + 1;
numTraces = min(metrics.eyeMaxTraces, numPossibleTraces);

firstStart = length(metrics.eyeBuffer) - ((numTraces - 1) * metrics.eyeSps + traceLen) + 1;
eyeX = (0:traceLen-1) / metrics.eyeSps;

for ii = 1:numTraces
    startIdx = firstStart + (ii-1) * metrics.eyeSps;
    stopIdx = startIdx + traceLen - 1;
    eyeY = metrics.eyeBuffer(startIdx:stopIdx);
    
    set(plotHandles.eyeLineHandles(ii), ...
        'XData',eyeX, ...
        'YData',eyeY);
end

for ii = numTraces+1:length(plotHandles.eyeLineHandles)
    set(plotHandles.eyeLineHandles(ii), ...
        'XData',NaN, ...
        'YData',NaN);
end

validEye = metrics.eyeBuffer(isfinite(metrics.eyeBuffer));
if ~isempty(validEye)
    yMin = min(validEye);
    yMax = max(validEye);
    if yMin == yMax
        yMin = yMin - 1e-3;
        yMax = yMax + 1e-3;
    end
    margin = 0.15 * (yMax - yMin);
    ylim(plotHandles.axEye,[yMin - margin, yMax + margin]);
end
xlim(plotHandles.axEye,[0 metrics.eyeSpanSymbols]);
end