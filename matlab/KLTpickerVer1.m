function KLTpickerVer1(micrograph_addr,output_dir,particle_size,num_of_particles,num_of_noise_images,gpu_use)
% 
% KLT picker
% 
%
% Amitay Eldar, Nov 2019

% Input:
% micrograph_addr       address of the micrographs .mrc files.
% output_dir            address to save coordinate file
% particle_size         particle size in pixels
% num_of_particles      number of particles to pick per micrograph. if set to -1
%                       then pick all particles
% num_of_noise_images   number of noise images to pick per micrograph
% gpu_use               if set to 1 then use the GPU.


% Output:
% coordinate files .box in output_dir
% Picking summery text file in output_dir.

%% Initielizing parameters
mgScale = 100/particle_size; % scaling to particle size of 100  pix which seems to give good results in practice
files = dir([micrograph_addr,'/','*.mrc']);
numOfMicro = size(files,1);
patchSz = floor(0.8*mgScale*particle_size);% apprx Par size after downSampling
patchSzFun = floor(0.4*mgScale*particle_size); % disk Sz for computing the eigen func
patchSzPickBox = floor(1*mgScale*particle_size); % box size
maxIter = 6*10^4; % max iterations for psd apprx
MaxNumOfFun= 400; % max eigen function to use.
maxOrder= 100;% order of maximum eigen function
precentOfEig = 0.99; % how many eigen function to develope
thresh = 0; % threshold for the picking.
showFig = 0; % show figs if set to 1.
preProcessStage = 1; % 1 to creat variables for all micrographs
microNames = cell(numOfMicro,1);
pickedParPerMic = zeros(numOfMicro,1);
pickedNoisePerMic = zeros(numOfMicro,1);

% automatic part
if mod(patchSz,2) == 0
    patchSz = patchSz -1;
end
if mod(patchSzFun,2) == 0
    patchSzFun = patchSzFun -1;
end

coordinatsPathParticle =[output_dir,'pickedParticles','ParticleSize',num2str(particle_size)];
coordinatsPathNoise =[output_dir,'pickedNoise','ParticleSize',num2str(particle_size)];
if ~exist(coordinatsPathParticle, 'dir')
   mkdir(coordinatsPathParticle)
end
if ~exist(coordinatsPathNoise, 'dir')
    if num_of_noise_images~=0
        mkdir(coordinatsPathNoise)
    end
end


%% PreProcess
disp("Starting preprocess");
if preProcessStage == 1
    T = 1; % Nyquist sampling rate
    bandLimit = pi/T;
    radMax =  floor((patchSzFun-1)/2);
    x = single(-radMax:1:radMax);
    [X,Y] = meshgrid(x);
    radMat = sqrt(X.^2+Y.^2); theta = atan2(Y,X);
    name=[' max order ',num2str(maxOrder),' precentOfEig ',num2str(precentOfEig)]; % for figures
    rSamp = radMat(:);
    theta = theta(:);
    numOfQuadKer =2^10;
    numOfQuadNys = 2^10;
    [rho,quadKer] = lgwt(numOfQuadKer,0,bandLimit);
    rho = flipud(single(rho)); quadKer = flipud(single(quadKer)); 
    [r,quadNys] = lgwt(numOfQuadNys,0,radMax);
    r = flipud(single(r)); quadNys = flipud(single(quadNys));
    % mat for finding eig
    rr = r*r';
    rRho = r*rho'; 
    % mat for sampeling eigfunction
    One = single(ones(length(rSamp),1));
    rSampr = One*r';
    rSampRho = rSamp*rho';
    sqrtrSampr = sqrt(rSampr);
    JrRho = single(zeros(size(rRho,1),size(rRho,2),length(0:maxOrder-1)));
    Jsamp = single(zeros(size(rSampRho,1),size(rSampRho,2),length(0:maxOrder-1)));
    cosine = single(zeros(length(theta),length(0:maxOrder-1)));
    sine = single(zeros(length(theta),length(0:maxOrder-1))); 
    parfor N=0:maxOrder-1
       JrRho(:,:,N+1) = single(besselj(N,rRho)); 
       Jsamp(:,:,N+1) = single(besselj(N,rSampRho));
        if N~=0
            cosine(:,N+1) = single(cos(N*theta));
            sine(:,N+1) = single(sin(N*theta));
        end
    end
end
disp('Preprocess finished');

%% main section
disp("Starting particle picking from micrographs")

% Initialize queue for progress messages
progressQ=parallel.pool.DataQueue;
afterEach(progressQ, @print_progress); % function defined at the end

parfor expNum = 1:numOfMicro
    startT=clock;
    [~, microName] = fileparts(files(expNum).name);
    mgBig = ReadMRC([files(expNum).folder,'/',files(expNum).name]);
    mgBig = double(mgBig);
    mgBigSz = min(size(mgBig));
    mgBig = mgBig(1:mgBigSz,1:mgBigSz);
    mgBig = rot90(mgBig);
    mgBigSz = size(mgBig,1);
    mg = cryo_downsample(mgBig,[floor(mgScale*size(mgBig,1)),floor(mgScale*size(mgBig,2))]);
    if mod(size(mg,1),2) == 0 % we need odd size
        mg = mg(1:end-1,1:end-1);
    end
    mg = mg - mean(mg(:));
    mg = mg/norm(mg,'fro'); % normalization; 
    mcSz = size(mg,1);

    %% Cutoff filter
    bandPass1d = fir1(patchSz-1, [0.05 0.95]);
    bandPass2d  = ftrans2(bandPass1d); %% radial bandpass
    if gpu_use == 1
        mg = imfilter(gpuArray(mg), bandPass2d);
        mg = gather(mg);
    else
        mg = imfilter(mg, bandPass2d);
    end
    noiseMc = mg; 
    
    %% Estimating particle and noise RPSD
    [apprxCleanPsd,apprxNoisePsd,~,R,~,stopPar] = rpsd_estimation(noiseMc,patchSz,maxIter);
    if stopPar==1 % maxIter happend, skip to next micro graph
        continue
    end
    if showFig==1
        figure('visible','on');
        plot(R*bandLimit,apprxCleanPsd,'LineWidth',4)
        grid on
        figName = ('apprx Clean Psd first stage ');
        legend('apprxCleanPsd')
        title(figName,'FontSize',9);
        figure('visible','on');
        plot(R*bandLimit,apprxNoisePsd,'LineWidth',4)
        grid on
        figName = ('apprx Noise Psd first stage ');
        legend('apprxNoisePsd')
        title(figName,'FontSize',9);
    end
   
    %% PreWhitening the micrograph
    apprxNoisePsd = apprxNoisePsd +(median(apprxNoisePsd)*(10^-1));% we dont want zeros
    [noiseMc] = prewhite(noiseMc,apprxNoisePsd,apprxCleanPsd,mcSz,patchSz,R);
    
    %% Re estimating particle and noise RPSD
    noiseMc = noiseMc - mean(noiseMc(:));
    noiseMc = noiseMc/norm(noiseMc,'fro'); % normalization; 
    [apprxCleanPsd,apprxNoisePsd,noiseVar,R,~,stopPar] = rpsd_estimation(noiseMc,patchSz,maxIter);
    if stopPar==1 % maxIter happend, skip to next micro graph
        continue
    end 
    if showFig==1
        figure('visible','on');
        plot(R*bandLimit,apprxCleanPsd,'LineWidth',4)
        grid on
        figName = ('apprx Clean Psd second stage ');
        legend('apprxCleanPsd')
        title(figName,'FontSize',9);
        figure('visible','on');
        plot(R*bandLimit,apprxNoisePsd,'LineWidth',4)
        grid on
        figName = ('apprx Noise Psd second stage ');
        legend('apprxNoisePsd')
        title(figName,'FontSize',9);
    end


    %% Constructing the KLTpicker templates
    psd = single(abs(spline(bandLimit*R,apprxCleanPsd,rho)));
    if showFig==1
        figure('visible','on');
        plot(rho,psd);
        figName = ['Clean Sig Samp at nodes ',name];
        title(figName);
    end
    [eigFun,eigVal] = construct_klt_templates(length(rSamp),rho,quadKer,quadNys,rr,sqrtrSampr,JrRho,Jsamp,cosine,sine,numOfQuadNys,maxOrder,psd,precentOfEig,gpu_use);
   if size(eigFun,2) < MaxNumOfFun 
        numOfFun = size(eigFun,2);
   else
        numOfFun = MaxNumOfFun;
   end


    %% particle detection
    [numOfPickedPar,numOfPickedNoise] = particle_detection(noiseMc,eigFun,eigVal,numOfFun,noiseVar,mcSz,mgScale,radMat,mgBigSz,patchSzPickBox,patchSzFun,num_of_particles,num_of_noise_images,coordinatsPathParticle,coordinatsPathNoise,microName,thresh,gpu_use);
    microNames{expNum} = microName;
    pickedParPerMic(expNum) = numOfPickedPar;
    pickedNoisePerMic(expNum) = numOfPickedNoise;
    
    % Report progress
    endT=clock;
    data=struct;
    data.i=expNum; data.n_mics=numOfMicro; data.t=etime(endT,startT);
    send(progressQ,data);
end
disp("Finished the picking successfully");
message = ['Picked ', num2str(sum(pickedParPerMic)),' particles and ',num2str(sum(pickedNoisePerMic)),' noise images out of ',num2str(numOfMicro),' micrographs.'];
disp(message);
% creating a text file the summerizes the number of picked particles and noise
disp("Writing Picking Summery at the output path");
pickingSummery = fopen(fullfile(output_dir,['pickingSummery','.txt']),'w');
fprintf(pickingSummery,'%s\n','Picking Summery');
fprintf(pickingSummery,'%s\n',message);
fprintf(pickingSummery,'%s\n','');
fprintf(pickingSummery,'%s\n','Picking per micrograph:');
fprintf(pickingSummery,'%s\n','Micrographs name #1');
fprintf(pickingSummery,'%s\n','Number of picked particles #2');
fprintf(pickingSummery,'%s\n','Number of picked noise images #3');
fprintf(pickingSummery,'%s\n','--------------------------------');
for i = 1:numOfMicro
    fprintf(pickingSummery,'%s\t%i\t%i\n',microNames{i},pickedParPerMic(i),pickedNoisePerMic(i));
end
fclose(pickingSummery);
disp("The KLT picker has finished");
end

function print_progress(data)
    persistent tot_mic
    persistent start_time
    
    if isempty(tot_mic)
        tot_mic = 0;
    end
    
    if isempty(start_time)
        start_time=clock; %Timestamp of starting time
    end
    
    tot_mic=tot_mic+1;
    tot_time=etime(clock,start_time);
    avg_time=tot_time/tot_mic;
    remaining_time=(data.n_mics-tot_mic)*avg_time;
    
    p=gcp('nocreate');
    if tot_mic > 2*p.NumWorkers
        fprintf('Done picking from micrograph %04d (%d/%d) in %3.0f secs (ETA %.0f mins)\n',...
            data.i,tot_mic,data.n_mics,data.t,remaining_time/60);
    else % Don't print ETA for the first 5 micrographs
        fprintf('Done picking from micrograph %04d (%d/%d) in %3.0f secs (ETA [still estimating])\n',...
            data.i,tot_mic,data.n_mics,data.t);
    end

end