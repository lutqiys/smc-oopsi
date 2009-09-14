function Enew = GOOPSI_Mstep_v1_0(Sim,S,M,E,F)
% this function finds the mle of the parameters
%
% Input---
% Sim:  simulation parameters
% R:    real data
% S:    simulation results
% M:    moments and sufficient stats
% E:    old parameter estimates
%
% Output is 'Enew', a structure with a field for each parameter, plus some
% additional fields for various likelihoods

Enew = E;   % initialize parameters
lik = [];   % initialize likelihood

optionsQP   = optimset('Display','off');
optionsGLM  = optimset('Display','off','GradObj','off','TolFun',1e-6);

%% MLE for spiking parameters
if Sim.n_params == true
    % MLE for spike rate parameters: baseline (b), linear filter (k), and spike history weights (omega)
    fprintf('\nestimating spike rate params\n')
    RateParams=E.k;                                         % vector of parameters to estimate (changes depending on user input of which parameters to estimate)
    sp      = S.n==1;                                       % find (particles,time step) pairs that spike
    nosp    = S.n==0;                                       % don't spike
    x       = repmat(Sim.x,1,Sim.N);                        % generate matrix for gradinent
    zeroy   = zeros(Sim.N,Sim.T);                           % make matrix of zeros for evaluating lik

    if Sim.h_params == true
        if Sim.M>0                                          % if spike history terms are present
            RateParams=[RateParams; E.omega];               % also estimate omega
            for i=1:Sim.M                                   % and modify stimulus matrix for gradient
                x(Sim.StimDim+i,:)=reshape(S.h(:,:,i),1,Sim.N*Sim.T);
            end
        end

        %[bko lik_r] = fminunc(@f_bko,RateParams,optionsGLM);% find MLE
        Z=ones(size(RateParams));
        [bko lik_r]=fmincon(@f_bko,RateParams,[],[],[],[],-10*Z,10*Z,[],optionsGLM);%fix for h-problem
        Enew.k      = bko(1:end-Sim.M);                     % set new parameter estimes
        if Sim.M>0, Enew.omega = bko(end-Sim.M+1:end); end   % for omega too
    else
        if Sim.M>0                                          % if spike history terms are present
            for i=1:Sim.M                                   % and modify stimulus matrix for gradient
                x(Sim.StimDim+i,:)=reshape(S.h(:,:,i),1,Sim.N*Sim.T);
            end
        end

        [bk lik_r]  = fminunc(@f_bk,RateParams,optionsGLM); % find MLE
        Enew.k      = bk(1:end);                            % set new parameter estimes
    end
    Enew.lik_r   = -lik_r;
    lik = [lik Enew.lik_r];
end

    function [lik dlik]= f_bko(RateParams)                  % get lik and grad

        xk      = RateParams(1:end-Sim.M)'*Sim.x;           % filtered stimulus
        hs      = zeroy;                                    % incorporate spike history terms
        for l=1:Sim.M, hs  = hs+RateParams(end-Sim.M+l)*S.h(:,:,l); end
        s       = repmat(xk,Sim.N,1) + hs;

        f_kdt   = exp(s)*Sim.dt;                            % shorthand
        ef      = exp(f_kdt);                               % shorthand
        lik     = -sum(S.w_b(sp).*log(1-1./ef(sp)))...      % liklihood
            +sum(S.w_b(nosp).*f_kdt(nosp));

        if nargout > 1                                      % if gradobj=on
            dlik      = -x(:,sp)*(S.w_b(sp).*f_kdt(sp)./(ef(sp)-1))... %gradient of lik
                + x(:,nosp)*(S.w_b(nosp).*f_kdt(nosp));
        end
    end %function f_bko

    function [lik dlik]= f_bk(RateParams)                   % get lik and grad

        xk      = RateParams'*Sim.x;                        % filtered stimulus
        hs      = zeroy;                                    % incorporate spike history terms
        for l=1:Sim.M, hs  = hs+E.omega*S.h(:,:,l); end
        s       = repmat(xk,Sim.N,1) + hs;

        f_kdt   = exp(s)*Sim.dt;                            % shorthand
        ef      = exp(f_kdt);                               % shorthand
        lik     = -sum(S.w_b(sp).*log(1-1./ef(sp)))...      % liklihood
            +sum(S.w_b(nosp).*f_kdt(nosp));

        if nargout > 1                                      % if gradobj=on
            dlik      = -x(:,sp)*(S.w_b(sp).*f_kdt(sp)./( ef(sp)-1))... % gradient of lik
                + x(:,nosp)*(S.w_b(nosp).*f_kdt(nosp));
        end
    end %function f_bko

%% MLE for calcium parameters
if Sim.C_params == true
    fprintf('estimating calcium parammeters\n')
    if(isfield(Sim,'holdTau') && Sim.holdTau == 1)          % THIS IS NOT CORRECT AND SHOULD BE FIXED
        [ve_x fval] = quadprog(M.Q(2:3,2:3), M.L(2:3),[],[],[],[],[0 0],[inf inf],[E.A E.C_0/E.tau_c]+eps,optionsQP);
        Enew.tau_c  = E.tau_c;
        Enew.A      = ve_x(1);
        Enew.C_0    = ve_x(2)/E.tau_c;
    else
        [ve_x fval] = quadprog(M.Q, M.L,[],[],[],[],[0 0 0],[inf inf inf],[1/E.tau_c E.A E.C_0/E.tau_c]+eps,optionsQP);
        Enew.tau_c  = 1/ve_x(1);
        Enew.A      = ve_x(2);
        Enew.C_0    = ve_x(3)/ve_x(1);
    end
    fval        = M.K/2 + fval;                             % variance
    Enew.sigma_c= sqrt(fval/(M.J*Sim.dt));                  % factor in dt
    Enew.lik_c  = - fval/(Enew.sigma_c*sqrt(Sim.dt)) - M.J*log(Enew.sigma_c);
    lik = [lik Enew.lik_c];
end

% % %% MLE for spike history parameters
% % for m=1:Sim.M
% %     Enew.sigma_h(m)= sum(M.v{m})/Sim.T;
% % end

%% MLE for observation parameters
if Sim.F_params == true
    fprintf('estimating observation parammeters\n')
    ab_0            = [E.alpha E.beta];
    [Enew.lik_o ab] = f1_ab(ab_0);
%     Enew.alpha = ab(1);
%     Enew.beta  = ab(2);
%     if Sim.G_params == true                                 % THIS IS NOT CORRECT AND SHOULD BE FIXED
%         Enew.zeta=E.zeta*ab(3);
% %         Enew.gamma = E.gamma*ab(3); 
%     end
%     lik = [lik Enew.lik_o];

if Sim.N==1, C=S.C; else C=sum(S.w_b.*S.C); end
    C1      = [Hill_v1(E,C); zeroy];
    ab      = C1'\F';
    Enew.alpha = ab(1);
    Enew.beta  = ab(2);
    Enew.zeta  = sqrt(sum((F-ab'*C1).^2)/Sim.T);


end

% if Sim.F_params == true
%     fprintf('estimating observation parameters\n')
%     ab_0            = [E.alpha E.beta];
%     [Enew.lik_o ab] = f1_abgz(ab_0,1);
%     Enew.alpha = ab(1);
%     Enew.beta  = ab(2);
%     lik = [lik Enew.lik_o];
% end
% 
% if Sim.G_params == true                                 % THIS IS NOT CORRECT AND SHOULD BE FIXED
%     fprintf('estimating noise parameters\n')
%     ab_0            = [E.gamma E.zeta];
%     [Enew.lik_n ab] = f1_abgz(ab_0,2);
%     Enew.gamma = ab(1);
%     Enew.zeta  = ab(2);
%     lik = [lik Enew.lik_n];
% end

    function [lik x] = f1_ab(ab_o)
        %find MLE for {alpha, beta} or  {gamma, zeta}
        %THIS EXPLICITLY ASSUMES WEIGHTS w_b ARE SUM=1 NORMALIZED (!)
        pfS=Hill_v1(E,S.C);
%         if ab==1,   
            pfV=E.gamma*pfS+E.zeta;
%         else        pfV=E.alpha*pfS+E.beta; end
        
        % minimize quadratic form of E[(F - ab(1)*pfS - ab(2))^2/pfV]
        % taken as weighted average over all particles (Fmean)
        f1_abn=sum(sum(S.w_b,2));       % normalization

        f1_abH(1,1) = sum(sum(pfS.^2./pfV.*S.w_b,2));% QF
        f1_abH(2,2) = sum(sum(S.w_b./pfV,2));
        f1_abH(1,2) = sum(sum(pfS./pfV.*S.w_b,2));
        f1_abH(2,1) = f1_abH(1,2);

        f1_abf=[0;0]; f1_abc=0;         % LF and offset
        for i=1:size(pfS,1)             % over particles
            f1_abf(1) = f1_abf(1) - sum(F(:)'.*pfS(i,:)./pfV(i,:).*S.w_b(i,:));
            f1_abf(2) = f1_abf(2) - sum(F(:)'./pfV(i,:).*S.w_b(i,:));

            f1_abc = f1_abc + sum(F(:)'.^2./pfV(i,:).*S.w_b(i,:));
        end

        % solve QP given ab(1)>0, no bound on ab(2)
        [x lik] = quadprog(f1_abH,f1_abf,[],[],[],[],[0 -inf],[inf inf],[],optionsQP);

        lik=(lik+f1_abc/2);             % variance
        x(3)=lik/f1_abn;                % estimate gamma_new/gamma

        lik=-lik-sum(sum(log(x(3)*pfV).*S.w_b,2))/2;
    end %function f_ab

Enew.lik=sum(lik);
end
