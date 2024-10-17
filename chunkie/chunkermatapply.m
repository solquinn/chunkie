function u = chunkermatapply(chnkr,kern,dens,cormat,opts)
%CHUNKERMATAPPLY - apply chunkermat system on chunker defined by kern
%
% Syntax:  u = chunkermatapply(chnkr,kern,dens,sigma,opts)
%
% Input:
%   chnkobj - chunker object describing boundary
%   kern  - kernel function. By default, this should be a function handle
%           accepting input of the form kern(srcinfo,targinfo), where srcinfo
%           and targinfo are in the ptinfo struct format, i.e.
%                ptinfo.r - positions (2,:) array
%                ptinfo.d - first derivative in underlying
%                     parameterization (2,:)
%                ptinfo.n - unit normals (2,:)
%                ptinfo.d2 - second derivative in underlying
%                     parameterization (2,:)
%   dens - density on boundary, should have size opdims(2) x k x nch
%          where k = chnkr.k, nch = chnkr.nch, where opdims is the 
%           size of kern for a single src,targ pair
%
% Optional input:
%   cormat - sparse matrix of corrections to the smooth quadrature rule
%            generated by chunkermat with option corrections = true
%            It will be computed if not provided.
%   opts  - options structure. available options (default settings)
%           opts.quad = string ('ggq'), specify quadrature routine to 
%                       use for neighbor and self interactoins. Other 
%                       available options include:
%                       - 'native' selects standard scaled Gauss-Legendre 
%                       quadrature for smooth integral kernels
%           opts.sing = string ('log') 
%                       default type of singularity of kernel in case it 
%                       is not defined by the kernel object. Supported 
%                       types are:
%                         smooth => smooth kernels
%                         log => logarithmically singular kernels or 
%                                smooth times log + smooth
%                         pv => principal value singular kernels + log
%                         hs => hypersingular kernels + pv
%
%           opts.l2scale = boolean (false), if true scale rows by 
%                           sqrt(whts) and columns by 1/sqrt(whts)
%           opts.auxquads = struct, struct storing auxilliary nodes 
%                     and weights which might be required for some of
%                     the quadrature methods like ggq for example.
%                     There is a different sub structure for each
%                     quadrature and singularity type which should be named
%                     as
%
%                     opts.auxquads.<opts.quad><opts.type> 
%                     
%                     For example, the structure for logarithmically
%                     singular kernels integrated using ggq
%                     quadrature, the relevant struct is
%                     
%                     opts.auxquads.ggqlog
%
%                     The specific precomputed variables and their values
%                     will depend on the quadrature method used.
%           opts.rcip = boolean (true), flag for whether to include rcip
%                      corrections for near corners if input chnkobj is
%                      of type chunkergraph
%           opts.rcip_ignore = [], list of vertices to ignore in rcip
%           opts.nsub_or_tol = (40) specify the level of refinements in rcip
%                    or a tolerance where the number of levels is given by
%                    ceiling(log_{2}(1/tol^2));
%           opts.adaptive_correction = (false) flag for whether to use
%                    adaptive quadrature for near touching panels on
%                    different chunkers
%           opts.eps = (1e-14) tolerance for adaptive quadrature
%           opts.flam - if = true, use flam utilities. to be replaced by the 
%                       opts.forceflam flag. 
%                       opts.flam supercedes opts.accel, if
%                       both are true, then flam will be used. (false)
%           opts.accel - if = true, use specialized fmm if defined 
%                       for the kernel, if it doesnt exist or if too few 
%                       sources/targets, or if false, 
%                       do direct. (true)
%           opts.forcefmm - if = true, use specialized fmm if defined,
%                       independent of the number of sources/targets. (false)
%
% Outputs:
%    u - system matrix applied to sigma
%
%
%
% See also: CHUNKERMAT


if isa(kern,'function_handle')
    kern2 = kernel(kern);
    kern = kern2;
elseif isa(kern,'cell')
    sz = size(kern);
    kern2(sz(1),sz(2)) = kernel();
    for j = 1:sz(2)
        for i = 1:sz(1)
            if isa(kern{i,j},'function_handle')
                kern2(i,j) = kernel(kern{i,j});
            elseif isa(kern{i,j},'kernel')
                kern2(i,j) = kern{i,j};
            else
                msg = "Second input is not a kernel object, function handle, " ...
                    + "or cell array";
                error(msg);
            end
        end
    end
    kern = kern2;
    
elseif ~isa(kern,'kernel')
    msg = "Second input is not a kernel object, function handle, " ...
                + "or cell array";
    error(msg);
end
    
if nargin < 4
    cormat = [];
end
if nargin < 5
    opts = [];
end



% get opts from struct if available


eps = 1e-14;
if isfield(opts,'eps')
    eps = opts.eps;
end

% Flag for determining whether input object is a chunkergraph
icgrph = 0;

if (class(chnkr) == "chunker")
    chnkrs = chnkr;
elseif(class(chnkr) == "chunkgraph")
    icgrph = 1;
    chnkrs = chnkr.echnks;
else
    msg = "First input is not a chunker or chunkgraph object";
    error(msg)
end


% check for local corrections
if isempty(cormat)
    selfopts = opts;
    selfopts.corrections = true;
    cormat = chunkermat(chnkr,kern,selfopts);
end

% preproccessing
nchunkers = length(chnkrs);

opdims_mat = zeros(2,nchunkers,nchunkers);
lchunks    = zeros(nchunkers,1);

%TODO: figure out a way to avoid this nchunkers^2 loop
fmmall = true;
for i=1:nchunkers
    
    targinfo = [];
   	targinfo.r = chnkrs(i).r(:,2); targinfo.d = chnkrs(i).d(:,2); 
   	targinfo.d2 = chnkrs(i).d2(:,2); targinfo.n = chnkrs(i).n(:,2);
    lchunks(i) = size(chnkrs(i).r(:,:),2);
    
    for j=1:nchunkers
        
        % determine operator dimensions using first two points

        srcinfo = []; 
        srcinfo.r = chnkrs(j).r(:,1); srcinfo.d = chnkrs(j).d(:,1); 
        srcinfo.d2 = chnkrs(j).d2(:,1); srcinfo.n = chnkrs(j).n(:,1);

        if (size(kern) == 1)
            ftemp = kern.eval(srcinfo,targinfo);
            fmmall = fmmall && ~isempty(kern.fmm);
        else
            ktmp = kern(i,j).eval;
            ftemp = ktmp(srcinfo,targinfo);
            fmmall = fmmall && ~isempty(kern(i,j).fmm);
        end   
        opdims = size(ftemp);
        opdims_mat(:,i,j) = opdims;
    end
end    

if ~fmmall
    msg = "chunkermatapply: this routine only recommended if fmm" + ...
        " is defined for all relevant kernels. Consider forming the dense matrix" + ...
        " or using chunkerflam instead";
    warning(msg);
end

irowlocs = zeros(nchunkers+1,1);
icollocs = zeros(nchunkers+1,1);

irowlocs(1) = 1;
icollocs(1) = 1;
for i=1:nchunkers
   icollocs(i+1) = icollocs(i) + lchunks(i)*opdims_mat(2,1,i);
   irowlocs(i+1) = irowlocs(i) + lchunks(i)*opdims_mat(1,i,1);
end

% apply local corrections and diagonal scaling
u = cormat*dens;

% apply smooth quadratures
if size(kern) == 1
    opts_smth = opts;
    % opts_smth.flam = true; % todo fix flam on vector valued kernels
    
    chnkrmerge = merge(chnkrs);
    
    targinfo = [];
    targinfo.r  = chnkrmerge.r(:,:);            
    targinfo.d  = chnkrmerge.d(:,:); 
    targinfo.d2 = chnkrmerge.d2(:,:); 
    targinfo.n  = chnkrmerge.n(:,:);

    u = u + chnk.chunkerkerneval_smooth(chnkrmerge,kern, ...
        opdims_mat(:,1,1),dens,targinfo,[],opts_smth);
else
    opts_smth = opts;
    % opts_smth.flam = true; % todo fix flam on vector valued kernels

    for i = 1:nchunkers
        targinfo = [];
        targinfo.r  = chnkrs(i).r(:,:);
        targinfo.d  = chnkrs(i).d(:,:);
        targinfo.d2 = chnkrs(i).d2(:,:);
        targinfo.n  = chnkrs(i).n(:,:);
        iids = irowlocs(i):(irowlocs(i+1)-1);
        for j = 1:nchunkers
            jids = icollocs(j):(icollocs(j+1)-1);
            u(iids) = u(iids) + chnk.chunkerkerneval_smooth(chnkrs(j), ...
                kern(i,j),opdims_mat(:,i,j),dens(jids),targinfo,[], ...
                opts_smth);
        end
    end
end

end
